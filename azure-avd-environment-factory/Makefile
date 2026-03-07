.PHONY: init fmt validate test lint security plan docs clean

init:
	terraform -chdir=terraform init -backend=false

fmt:
	terraform fmt -recursive

validate: init
	terraform -chdir=terraform validate

test: init
	terraform -chdir=terraform test

lint:
	tflint --recursive --chdir=terraform

security:
	trivy config terraform

plan:
	terraform -chdir=terraform plan -var-file=environments/dev/terraform.tfvars

docs:
	terraform-docs markdown table --output-file README.md --output-mode inject terraform

clean:
	find terraform -type d -name .terraform -prune -exec rm -rf {} +
	find terraform -type f -name '*.tfplan' -delete
