terraform {
  backend "s3" {
    bucket         = "stocks-serverless-pipeline-terraform-state-876442842164"
    key            = "env/dev/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "stocks-serverless-pipeline-terraform-locks"
    encrypt        = true
  }
}
