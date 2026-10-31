# AWS Resource Tracker

Bash script that lists resources in an AWS account that can quietly cost money: running and stopped EC2, EBS volumes (including unattached), snapshots, AMIs, Elastic IPs, NAT gateways, load balancers, RDS, EKS, ECR, log groups, DynamoDB, EFS, Secrets Manager, IAM users and old access keys. It also shows the remaining Free Plan credits.

## Design
- Each check runs in the background and the results are merged, so a full run takes about 13 seconds instead of minutes.
- Uses the AWS CLI `--query` (JMESPath) instead of `jq`.
- Needs only read-only IAM permissions.
- Writes a dated report and deletes reports older than 7 days.

## Usage

    aws configure          # read-only IAM user
    chmod +x aws-resource-tracker.sh
    ./aws-resource-tracker.sh

Optional cron (daily 18:00, use full paths):

    0 18 * * * /home/<user>/aws-tracker/aws-resource-tracker.sh >> /home/<user>/aws-tracker/cron.log 2>&1

Reports and logs are git-ignored because they contain account details.
