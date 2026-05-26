nexatech-infra/
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── providers.tf
│   ├── modules/
│   │   ├── vpc/
│   │   ├── ec2/
│   │   ├── rds/
│   │   ├── ecr/
│   │   ├── iam/
│   │   └── alb/
│   └── environments/
│       └── dev.tfvars
│       └── prod.tfvars
├── ansible/
│   ├── inventory/
│   ├── playbooks/
│   │   ├── deploy-infra.yml
│   │   ├── deploy-app.yml
│   │   └── update-all.yml
│   └── roles/
│       ├── docker/
│       ├── java-service/
│       └── nodejs-python/
├── docker-compose/
│   ├── infra-1.docker-compose.yml
│   ├── app-1.docker-compose.yml
│   └── app-2.docker-compose.yml
└── scripts/