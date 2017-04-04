# gp-localci-client
Pot generation client for GP LocalCI (https://github.com/Automattic/gp-localci)

### Usage
1. Clone the repo into your project build at your CI
2. Run generate-new-string-comparison.sh

### Authentication
The client makes multiple Github API requests every time it runs.
To reduce the risk of being rate limited by Github, set the following environment variables (in your CircleCI app config, for example):
- `LOCALCI_APP_ID`
- `LOCALCI_APP_SECRET`
