/*
  Infrastructure for AVD patch management.

  Creates:
    - a storage account and private container for staged updates
    - an Automation Account with a system-assigned identity to run script 1
    - RBAC: the automation identity writes, session hosts only read
    - a schedule that fires on the second Tuesday of every month

  The schedule is the reason this is Bicep rather than a portal click. Azure
  Automation supports monthly-occurrence triggers natively (occurrence 2,
  day Tuesday), so "Patch Tuesday" is expressed declaratively instead of being
  recalculated by a script that has to guess the date.

  Deploy:
    az deployment group create -g rg-avd-patching -f main.bicep -p main.bicepparam
*/

targetScope = 'resourceGroup'

@description('Prefix for resource names. Must be lowercase alphanumeric.')
@minLength(3)
@maxLength(11)
param namePrefix string = 'avdpatch'

@description('Azure region. Defaults to the resource group location.')
param location string = resourceGroup().location

@description('Blob container name for staged updates.')
param patchContainerName string = 'patches'

@description('Days after which staged updates are deleted. Keep at least two cycles so a rollback target exists.')
@minValue(30)
@maxValue(730)
param patchRetentionDays int = 120

@description('Principal IDs of the session host managed identities that need read access. Leave empty and grant at the VM or group level afterwards.')
param sessionHostPrincipalIds array = []

@description('UTC hour at which the download runbook fires on Patch Tuesday.')
@minValue(0)
@maxValue(23)
param downloadHourUtc int = 20

@description('Tags applied to every resource.')
param tags object = {
  workload: 'avd-patch-management'
  managedBy: 'bicep'
}

var storageAccountName = toLower('st${namePrefix}${uniqueString(resourceGroup().id)}')
var automationAccountName = '${namePrefix}-automation'

// Built-in role definition IDs.
var storageBlobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var storageBlobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

// ---------------------------------------------------------------------------
// Storage
// ---------------------------------------------------------------------------

resource storageAccount 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageAccountName
  location: location
  tags: tags
  sku: {
    // LRS is sufficient: everything here is re-downloadable from Microsoft.
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    // Session hosts authenticate with managed identity, so shared keys are not
    // needed. Disabling them removes the credential most likely to be leaked.
    allowSharedKeyAccess: false
    allowBlobPublicAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      // Tighten to the AVD subnet(s) via a private endpoint or service endpoint
      // in production. Left open here so the template deploys unmodified.
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    encryption: {
      services: {
        blob: {
          enabled: true
        }
      }
      keySource: 'Microsoft.Storage'
    }
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 30
    }
    containerDeleteRetentionPolicy: {
      enabled: true
      days: 30
    }
  }
}

resource patchContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: patchContainerName
  properties: {
    publicAccess: 'None'
  }
}

resource lifecyclePolicy 'Microsoft.Storage/storageAccounts/managementPolicies@2023-05-01' = {
  parent: storageAccount
  name: 'default'
  properties: {
    policy: {
      rules: [
        {
          name: 'expire-old-patches'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['${patchContainerName}/20']
            }
            actions: {
              baseBlob: {
                // Updates are large and only the current cycle is ever
                // installed, so old ones are deleted rather than archived.
                delete: {
                  daysAfterCreationGreaterThan: patchRetentionDays
                }
              }
            }
          }
        }
        {
          name: 'expire-old-reports'
          enabled: true
          type: 'Lifecycle'
          definition: {
            filters: {
              blobTypes: ['blockBlob']
              prefixMatch: ['${patchContainerName}/reports/']
            }
            actions: {
              baseBlob: {
                delete: {
                  daysAfterCreationGreaterThan: 365
                }
              }
            }
          }
        }
      ]
    }
  }
}

// ---------------------------------------------------------------------------
// Automation account for the downloader
// ---------------------------------------------------------------------------

resource automationAccount 'Microsoft.Automation/automationAccounts@2023-11-01' = {
  name: automationAccountName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    sku: {
      name: 'Basic'
    }
    publicNetworkAccess: true
    disableLocalAuth: false
  }
}

resource downloadRunbook 'Microsoft.Automation/automationAccounts/runbooks@2023-11-01' = {
  parent: automationAccount
  name: 'Invoke-PatchDownload'
  location: location
  tags: tags
  properties: {
    runbookType: 'PowerShell72'
    logVerbose: true
    logProgress: false
    description: 'Downloads the current cycle of security updates from the Microsoft Update Catalog into blob storage.'
  }
}

/*
  Patch Tuesday, declaratively.

  monthlyOccurrences with occurrence: 2 and day: Tuesday is exactly "the second
  Tuesday of every month" - no date arithmetic and nothing to drift.

  startTime must be in the future at deploy time or the API rejects it, so it is
  computed from the deployment timestamp rather than hard-coded.
*/
param baseTime string = utcNow('u')
var nextMonth = dateTimeAdd(baseTime, 'P1M')
var scheduleStart = '${substring(nextMonth, 0, 8)}01T${padLeft(string(downloadHourUtc), 2, '0')}:00:00Z'

resource patchTuesdaySchedule 'Microsoft.Automation/automationAccounts/schedules@2023-11-01' = {
  parent: automationAccount
  name: 'patch-tuesday-download'
  properties: {
    description: 'Fires on the second Tuesday of every month (Patch Tuesday).'
    startTime: scheduleStart
    frequency: 'Month'
    interval: 1
    timeZone: 'UTC'
    advancedSchedule: {
      monthlyOccurrences: [
        {
          occurrence: 2
          day: 'Tuesday'
        }
      ]
    }
  }
}

resource scheduleLink 'Microsoft.Automation/automationAccounts/jobSchedules@2023-11-01' = {
  parent: automationAccount
  name: guid(automationAccount.id, downloadRunbook.name, patchTuesdaySchedule.name)
  properties: {
    runbook: {
      name: downloadRunbook.name
    }
    schedule: {
      name: patchTuesdaySchedule.name
    }
  }
}

// ---------------------------------------------------------------------------
// RBAC
// ---------------------------------------------------------------------------

// The downloader writes patches and manifests.
resource automationBlobContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: storageAccount
  name: guid(storageAccount.id, automationAccount.id, storageBlobDataContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataContributorRoleId)
    principalId: automationAccount.identity.principalId
    principalType: 'ServicePrincipal'
  }
}

/*
  Session hosts get READ only.

  This is the important half of the model. A session host is a shared,
  user-facing machine; if one is compromised, read-only access means the
  attacker cannot replace next month's .msu and have every other host in the
  fleet install it as SYSTEM.

  The trade-off is that hosts cannot write their own compliance reports with
  this role alone. Grant Storage Blob Data Contributor scoped to the reports/
  prefix if you want host-written reports, or collect them via Log Analytics
  instead.
*/
resource sessionHostBlobReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for principalId in sessionHostPrincipalIds: {
    scope: storageAccount
    name: guid(storageAccount.id, principalId, storageBlobDataReaderRoleId)
    properties: {
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', storageBlobDataReaderRoleId)
      principalId: principalId
      principalType: 'ServicePrincipal'
    }
  }
]

// ---------------------------------------------------------------------------
// Outputs
// ---------------------------------------------------------------------------

output storageAccountName string = storageAccount.name
output patchContainerName string = patchContainer.name
output automationAccountName string = automationAccount.name
output automationPrincipalId string = automationAccount.identity.principalId
output manifestUrl string = '${storageAccount.properties.primaryEndpoints.blob}${patchContainerName}/manifests/latest.json'
output nextScheduleStart string = scheduleStart
