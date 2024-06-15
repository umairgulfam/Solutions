# Upload this project to a public GitHub repository

## Git workflow (recommended)

1. Extract `secret-expiry-radar.zip`.
2. Create a new **empty** public repository named `secret-expiry-radar` on GitHub. Do not pre-create a README or license; this package includes them.
3. Open a terminal in the extracted `secret-expiry-radar` folder.
4. Review the file list before committing. Never include `.env`, database files, backup files, or real inventory exports.

```bash
git init
git branch -M main
git add .
git status --short
git diff --cached --stat
git commit -m "Initial release: Secret Expiry Radar"
git remote add origin https://github.com/YOUR-USERNAME/secret-expiry-radar.git
git push -u origin main
```

Replace `YOUR-USERNAME` with your GitHub username. Authenticate with GitHub CLI or a credential manager, never a token embedded in the remote URL. Do not run `git add .` in a folder that contains private exports. `.gitignore` reduces common mistakes but cannot identify sensitive data in arbitrary filenames.

## Browser upload

Upload the extracted folder's **contents** using GitHub's upload-files flow. Enable hidden-file visibility to include `.github`, `.gitignore`, `.dockerignore`, and `.env.example`. The Git workflow is more reliable for hidden directories. Confirm the Actions tab shows the `Validate` workflow.

## Repository details

Suggested description:

> Metadata-only credential expiry and rotation monitoring with a dashboard, TLS/AWS/Azure collectors, Slack/email/PagerDuty alerts, Docker, and GitHub Actions.

Suggested topics: `devops`, `cloud`, `python`, `security`, `secret-management`, `certificate-monitoring`, `docker`, `azure`, `aws`, `platform-engineering`.

Enable secret scanning and push protection where available, review repository visibility, and configure branch protection as appropriate. Keep confidential infrastructure metadata out of screenshots and issues.

Do not enable GitHub Pages for the backend application: Pages cannot run Python, SQLite, or the scheduled worker. Deploy to your own suitable host; publish only synthetic screenshots or static project documentation through Pages.

This package has not created or uploaded a GitHub repository. It is ready for you to review and push.
