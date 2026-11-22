terraform {
  backend "s3" {
    bucket       = "ct-tfstate-eyoel-2838"
    key          = "contract-tracker/terraform.tfstate"
    region       = "us-west-2"
    encrypt      = true
    use_lockfile = true
  }
}