# Prerequisites — accounts, keys and credentials

Everything you must have **before** the first `terraform init` and **before** the
first Ansible run. Read the two checklists in order; the ordering matters because
the image has to exist in ECR before Ansible deploys.

The intended flow:

```
terraform apply  ->  GitHub Actions builds + pushes image to ECR  ->  ansible-playbook pulls it
```

---

## 0. TL;DR checklist

| # | Item | Needed by | Where it goes |
|---|------|-----------|---------------|
| 1 | AWS account (billing enabled) | Terraform | — |
| 2 | AWS region chosen | Terraform, CI, host | `terraform.tfvars`, GitHub `AWS_REGION` |
| 3 | AWS credentials for the Terraform principal | Terraform | `AWS_PROFILE` / env / SSO |
| 4 | EC2 SSH key pair (public key, or existing key name) | Terraform | `tfvars: ssh_public_key` / `key_name` |
| 5 | Domain name + ACME email | Terraform, host | `tfvars: domain`, `letsencrypt_email` |
| 6 | GitHub repo slug (`owner/name`) for OIDC | Terraform | `tfvars: github_repository` |
| 7 | Route 53 hosted zone ID (optional) | Terraform | `tfvars: route53_zone_id` |
| 8 | GitHub repository secrets/variables | CI | repo settings (after `apply`) |
| 9 | AWS credentials on the Ansible control node | Ansible | `AWS_PROFILE` / env |
| 10 | SSH **private** key | Ansible | `~/.ssh/...` |
| 11 | Ansible Vault password | Ansible | `--ask-vault-pass` |
| 12 | Image already pushed to ECR | Ansible | produced by CI |

Items **1–7** must exist before `terraform apply` (and therefore before `init`
in practice). Items **8–12** must exist before `ansible-playbook`.

---

## 1. Accounts

### AWS account
- An AWS account with billing enabled. Record the **account ID** and pick a
  **region** you will use everywhere (Terraform, GitHub Actions, RDS, EC2).
- An **IAM principal for Terraform** — an IAM user with access keys, an assumed
  role, or IAM Identity Center (SSO) credentials. It must be able to create the
  resources in §2. The minimum policy is in §7.
- **Service quotas**: a fresh account usually allows one Elastic IP and one
  `db.t4g.medium`; raise RDS/EC2 quotas if you plan to scale.
- **Billing guard** (recommended): a budget alert before you `apply`.

> You do **not** need a pre-created VPC, subnet, ECR repo, IAM role, key pair in
> AWS, or an RDS instance. Terraform creates all of those.

### GitHub
- A GitHub account/organisation with **Actions enabled** on the repo that holds
  this project. Actions → General → Workflow permissions may need
  "Read and write" only if you later commit artifacts; the OIDC flow here does
  not.
- The repository that holds the **custom app** (`apps.json` → `SOLRISE_APP_URL`).
  If it is private, you need a token for the build (see §5).
- If your organisation restricts OIDC, the repo must be allowed to use
  `id-token: write`. This is enabled per-workflow in
  `.github/workflows/build-image.yml`.

### DNS
- A domain you control. Either a **Route 53 hosted zone** in the same account
  (then set `route53_zone_id`) or your registrar's DNS (then create the A record
  yourself after `apply`, pointing at the Elastic IP output).
- Use a subdomain such as `erp.example.com`.

---

## 2. What Terraform creates for you (no keys needed in advance)

So you know you are *not* missing anything for these:

| Resource | Purpose |
|---|---|
| ECR repository | image registry that GitHub Actions pushes to |
| GitHub OIDC provider + CI role | lets Actions assume an AWS role with **no static keys** |
| RDS master password (Secrets Manager) | AWS-generated and rotated; never in a `.tfvars` or Vault |
| EC2 IAM role / instance profile | allows the host to pull from ECR and read the secret |
| VPC, subnets, security groups, Elastic IP, Route 53 record, S3 backup bucket | infrastructure |

---

## 3. Before `terraform init` / `apply`

### 3.1 Tooling on your workstation
| Tool | Minimum | Check |
|---|---|---|
| Terraform | 1.5 | `terraform version` |
| AWS CLI | v2 | `aws --version` |
| `git` | any recent | `git --version` |

### 3.2 AWS credentials in your environment
```bash
export AWS_PROFILE=my-terraform-profile     # or AWS_ACCESS_KEY_ID / _SECRET_ACCESS_KEY (+ _SESSION_TOKEN)
aws sts get-caller-identity                 # must succeed before you continue
```

### 3.3 Values to fill into `terraform.tfvars`
| Variable | Example | Notes |
|---|---|---|
| `aws_region` | `us-east-1` | use the same region everywhere |
| `domain` | `erp.example.com` | A record + Let's Encrypt |
| `letsencrypt_email` | `ops@example.com` | ACME contact |
| `ssh_public_key` | `ssh-ed25519 AAAA... you@laptop` | Terraform creates the key pair |
| `key_name` | `my-existing-key` | alternative to `ssh_public_key` |
| `ssh_private_key_path` | `~/.ssh/id_ed25519` | written into the Ansible inventory |
| `ssh_cidr_blocks` | `["203.0.113.4/32"]` | lock SSH to your egress IP |
| `github_repository` | `acme/solrise-app` | enables the CI role |
| `github_oidc_branch` | `refs/heads/main` | only this ref may push |
| `create_github_oidc_provider` | `true` | set `false` if the account already has one |
| `route53_zone_id` | `Z0123...` | optional; omit to manage DNS yourself |
| `db_engine_version` / `db_parameter_group_family` | `11.4` / `mariadb11.4` | verify both are offered in your region |

Generate the SSH key if you need one:
```bash
ssh-keygen -t ed25519 -f ~/.ssh/solrise_ed25519 -C solrise
cat ~/.ssh/solrise_ed25519.pub      # paste into ssh_public_key
```

Verify the RDS engine/version exists before `apply`:
```bash
aws rds describe-db-engine-versions --engine mariadb \
  --query 'DBEngineVersions[].EngineVersion' --output table
```

### 3.4 Terraform state (recommended)
For anything shared or long-lived, use the S3 backend commented out in
`infra/terraform/versions.tf`. That needs a **state bucket** and (optionally) a
**DynamoDB lock table** created out of band, plus the permissions in §7
(`TerraformState`, `StateLock`).

### 3.5 Then
```bash
cd infra/terraform
terraform init
terraform apply
```

Record these outputs — you need them next:

```bash
terraform output github_actions_role_arn
terraform output ecr_repository_url
terraform output app_public_ip
terraform output rds_endpoint
terraform output db_secret_arn
```

---

## 4. Before the image can be built (GitHub repository settings)

Set these in **Settings → Secrets and variables → Actions**.

### Repository **variables** (not secret)
| Name | Value | Source |
|---|---|---|
| `AWS_REGION` | `us-east-1` | your choice |
| `AWS_ROLE_ARN` | `arn:aws:iam::<acct>:role/<prefix>-github-actions` | `terraform output github_actions_role_arn` |
| `ECR_REPOSITORY_URL` | `<acct>.dkr.ecr.<region>.amazonaws.com/solrise/erpnext` | `terraform output ecr_repository_url` |
| `CUSTOM_TAG` | e.g. `version-15` | **must match** `custom_tag` in `infra/ansible/group_vars/all/main.yml` |
| `FRAPPE_BRANCH` | `version-15` | must match `frappe_branch` on the host |
| `SOLRISE_APP_BRANCH` | `version-15` | branch of the custom app |

### Repository **secret**
| Name | Value | Notes |
|---|---|---|
| `SOLRISE_APP_URL` | `https://x-access-token:<PAT>@github.com/acme/solrise_erp` | needed only if the custom app repo is private; the PAT needs `repo` read. It is consumed only inside the build and never printed. |

The workflow also reads `CUSTOM_TAG` (variable) and an optional `workflow_dispatch`
`tag` input.

> **One-time account note:** if `create_github_oidc_provider = false`, the existing
> provider's trust policy must already allow `token.actions.githubusercontent.com`
> with audience `sts.amazonaws.com`.

---

## 5. Before Ansible

### 5.1 Tooling on the control node
| Tool | Minimum |
|---|---|
| `ansible-core` | 2.15 |
| `amazon.aws` collection | 7.0 (`ansible-galaxy collection install -r infra/ansible/requirements.yml`) |
| `community.general`, `ansible.posix` | per `requirements.yml` |
| `python3-boto3` / `botocore` | for the Secrets Manager lookup and the optional dynamic inventory |
| SSH client | any |

```bash
pip install --user ansible-core boto3 botocore
cd infra/ansible && ansible-galaxy collection install -r requirements.yml
```

### 5.2 AWS credentials on the control node
Ansible reads the RDS master password from **Secrets Manager**, so the control
node needs read access to that one secret (the Ansible *host* does not — it uses
its instance role):

```bash
export AWS_PROFILE=my-ansible-profile
```

Minimum permissions for that principal:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadRdsSecret",
      "Effect": "Allow",
      "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
      "Resource": "<db_secret_arn from terraform output>"
    },
    {
      "Sid": "DynamicInventoryOptional",
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeTags"],
      "Resource": "*"
    }
  ]
}
```

### 5.3 SSH private key
The private half of the key whose public half you gave Terraform
(`ssh_private_key_path`), reachable from the control node. Confirm you can connect
before running the playbook:

```bash
ssh -i ~/.ssh/solrise_ed25519 ubuntu@$(terraform -chdir=infra/terraform output -raw app_public_ip)
```

### 5.4 Ansible Vault password
```bash
cd infra/ansible
cp group_vars/all/vault.example.yml group_vars/all/vault.yml
$EDITOR group_vars/all/vault.yml          # set vault_admin_password
ansible-vault encrypt group_vars/all/vault.yml
```
Keep the vault password itself in your password manager / CI secret store.

### 5.5 The image must already be in ECR
Ansible **pulls**; it does not build by default. Trigger the build first:

```bash
gh workflow run build-image.yml -f tag=version-15     # or push to main
gh run watch
```

(Or build and push from your workstation — see §6.)

### 5.6 Then
```bash
cd infra/ansible
ansible-playbook site.yml --ask-vault-pass
```

---

## 6. Manual image push (no CI)

If you would rather build locally and push by hand:

```bash
export AWS_PROFILE=my-terraform-profile
export AWS_REGION=us-east-1
ECR=$(terraform -chdir=infra/terraform output -raw ecr_repository_url)

aws ecr get-login-password --region "$AWS_REGION" \
  | podman login --username AWS --password-stdin "${ECR%%/*}"

# .env: CUSTOM_IMAGE="$ECR", CUSTOM_TAG=version-15, SOLRISE_APP_URL=..., FRAPPE_BRANCH=version-15
make image
./scripts/push-image.sh
```

Your own principal needs `ecr:GetAuthorizationToken` plus the push actions in
§7 (`Ecr`).

---

## 7. Minimum IAM policy for the Terraform principal

This is a practical starting point. It is broad in places (`ec2:Describe*`,
`rds:*`); scope it down to your organisation's standards. `AdministratorAccess`
works for a first bring-up but is not recommended for ongoing use.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
        "s3:GetBucketLocation", "s3:GetBucketVersioning"
      ],
      "Resource": [
        "arn:aws:s3:::my-tfstate-bucket",
        "arn:aws:s3:::my-tfstate-bucket/*"
      ]
    },
    {
      "Sid": "StateLock",
      "Effect": "Allow",
      "Action": [
        "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:DescribeTable"
      ],
      "Resource": ["arn:aws:dynamodb:us-east-1:123456789012:table/terraform-locks"]
    },
    {
      "Sid": "NetworkAndCompute",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "ec2:CreateVpc", "ec2:DeleteVpc", "ec2:ModifyVpcAttribute",
        "ec2:CreateSubnet", "ec2:DeleteSubnet", "ec2:ModifySubnetAttribute",
        "ec2:CreateInternetGateway", "ec2:DeleteInternetGateway",
        "ec2:AttachInternetGateway", "ec2:DetachInternetGateway",
        "ec2:CreateRouteTable", "ec2:DeleteRouteTable", "ec2:CreateRoute", "ec2:DeleteRoute",
        "ec2:AssociateRouteTable", "ec2:DisassociateRouteTable",
        "ec2:CreateSecurityGroup", "ec2:DeleteSecurityGroup",
        "ec2:AuthorizeSecurityGroupIngress", "ec2:AuthorizeSecurityGroupEgress",
        "ec2:RevokeSecurityGroupIngress", "ec2:RevokeSecurityGroupEgress",
        "ec2:RunInstances", "ec2:TerminateInstances", "ec2:StopInstances", "ec2:StartInstances",
        "ec2:CreateTags", "ec2:DeleteTags",
        "ec2:AllocateAddress", "ec2:ReleaseAddress", "ec2:AssociateAddress", "ec2:DisassociateAddress",
        "ec2:CreateKeyPair", "ec2:DeleteKeyPair", "ec2:ImportKeyPair",
        "ec2:CreateVolume", "ec2:DeleteVolume", "ec2:AttachVolume", "ec2:DetachVolume"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Rds",
      "Effect": "Allow",
      "Action": ["rds:*"],
      "Resource": "*"
    },
    {
      "Sid": "IamForRolesAndOidc",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateAssumeRolePolicy",
        "iam:TagRole", "iam:ListInstanceProfilesForRole",
        "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:ListAttachedRolePolicies",
        "iam:PutRolePolicy", "iam:GetRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
        "iam:CreatePolicy", "iam:DeletePolicy", "iam:GetPolicy", "iam:GetPolicyVersion",
        "iam:ListPolicyVersions", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
        "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
        "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
        "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
        "iam:GetOpenIDConnectProvider", "iam:TagOpenIDConnectProvider",
        "iam:PassRole"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Ecr",
      "Effect": "Allow",
      "Action": [
        "ecr:CreateRepository", "ecr:DeleteRepository", "ecr:DescribeRepositories",
        "ecr:GetAuthorizationToken", "ecr:PutLifecyclePolicy", "ecr:GetLifecyclePolicy",
        "ecr:TagResource", "ecr:ListTagsForResource",
        "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3Backups",
      "Effect": "Allow",
      "Action": [
        "s3:CreateBucket", "s3:DeleteBucket", "s3:ListBucket",
        "s3:GetBucketLocation", "s3:GetBucketVersioning", "s3:PutBucketVersioning",
        "s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock",
        "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
        "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
        "s3:GetBucketTagging", "s3:PutBucketTagging"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:CreateSecret", "secretsmanager:DeleteSecret", "secretsmanager:DescribeSecret",
        "secretsmanager:GetSecretValue", "secretsmanager:TagResource",
        "secretsmanager:PutResourcePolicy", "secretsmanager:GetResourcePolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Route53",
      "Effect": "Allow",
      "Action": [
        "route53:GetHostedZone", "route53:ListHostedZones", "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets", "route53:GetChange"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Identity",
      "Effect": "Allow",
      "Action": ["sts:GetCallerIdentity"],
      "Resource": "*"
    }
  ]
}
```

---

## 8. Hygiene

- **No static AWS keys in GitHub.** The CI role is assumed via OIDC; the only
  long-lived secret in GitHub is `SOLRISE_APP_URL` (a scoped PAT), and only when
  the custom app is private.
- **No DB password anywhere in your config.** RDS rotates it in Secrets Manager;
  the host reads it through its instance role, the control node through the
  policy in §5.2.
- **Encrypt the vault file** and keep the vault password out of the repo.
- **Restrict `ssh_cidr_blocks`** to your egress IP; prefer SSM Session Manager
  (`terraform output ssm_start_session_command`) over opening SSH at all.
- **Keep tags in sync.** `CUSTOM_TAG` (GitHub) and `custom_tag` (Ansible) must
  match, and both must match what the workflow pushed, or `podman pull` fails.
