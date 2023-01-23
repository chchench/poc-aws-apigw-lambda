terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 3.69.0"
    }
  }
}

variable "target-region" {
  type = string
  default = "us-east-1"
}

variable "target-user-profile" {
  type = string
  default = "default"
}

variable "stack" {
  type = string
  default = "test-"
}

variable "domain-name" {
  type = string
  default = ""
}

variable "domain-certificate-arn" {
  type = string
  default = ""
}




provider "aws" {
  region  = var.target-region
  profile = var.target-user-profile
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
    target-account-id = data.aws_caller_identity.current.account_id
}



# Role for enabling CloudWatch logging by API Gateway

module "api_gateway_cloudwatch_role" {
  source = "dod-iac/api-gateway-cloudwatch-role/aws"
  name   = "${var.stack}api-gateway-cloudwatch-role"
  tags = {
    Automation = "Terraform"
  }
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = module.api_gateway_cloudwatch_role.arn
}


# API Gateway

resource "aws_api_gateway_rest_api" "restapi" {
  name        = "restapi"
  description = "This is the client API endpoint"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# API Gateway - lookup

resource "aws_api_gateway_resource" "restapi-resource-lookup" {
  rest_api_id = aws_api_gateway_rest_api.restapi.id
  parent_id   = aws_api_gateway_rest_api.restapi.root_resource_id
  path_part   = "lookup"
}

resource "aws_api_gateway_method" "restapi-lookup-method" {
  rest_api_id      = aws_api_gateway_rest_api.restapi.id
  resource_id      = aws_api_gateway_resource.restapi-resource-lookup.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = "true"
}

resource "aws_api_gateway_method_settings" "restapi-lookup-method-settings" {
  rest_api_id = aws_api_gateway_rest_api.restapi.id
  stage_name  = aws_api_gateway_stage.restapi-dev.stage_name
  method_path = "*/*"
  settings {
    logging_level      = "INFO"
    data_trace_enabled = true
    metrics_enabled    = true
  }
}

resource "aws_api_gateway_integration" "restapi-lookup-integration" {
  rest_api_id             = aws_api_gateway_rest_api.restapi.id
  resource_id             = aws_api_gateway_resource.restapi-resource-lookup.id
  http_method             = aws_api_gateway_method.restapi-lookup-method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.restapi-lookup-lambda.invoke_arn
}


# Lambda

resource "aws_lambda_permission" "allow-from-api-gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.restapi-lookup-lambda.function_name
  principal     = "apigateway.amazonaws.com"

  # More: http://docs.aws.amazon.com/apigateway/latest/developerguide/api-gateway-control-access-using-iam-policies-to-invoke-api.html
  source_arn = "arn:aws:execute-api:${var.target-region}:${local.target-account-id}:${aws_api_gateway_rest_api.restapi.id}/*/${aws_api_gateway_method.restapi-lookup-method.http_method}${aws_api_gateway_resource.restapi-resource-lookup.path}"
}

# Creation of archive file for code before uploading to lambda

/*
resource "null_resource" "build_lambda_exec" {
  triggers = {
    source_code_hash = "${filebase64sha256("lambda_function_payload-python.py")}"
  }
  provisioner "local-exec" {
    command     = "build.sh"
    working_dir = "./"
  }
}
*/

data "archive_file" "lambda_function_payload" {
  type        = "zip"
  source_file = "lambda_function_lookup.js"
  output_path = "lambda_function_payload.zip"

  #  depends_on = ["null_resource.build_lambda_exec"]
}

resource "aws_lambda_function" "restapi-lookup-lambda" {
  function_name = "restapi-lookup-lambda"
  role          = aws_iam_role.role.arn

  filename         = "lambda_function_payload.zip"
  source_code_hash = data.archive_file.lambda_function_payload.output_base64sha256

  #  runtime       = "python3.8"
  #  handler       = "lambda_function_payload-python.lambda_handler"

  handler = "lambda_function_lookup.handler"
  runtime = "nodejs12.x"

}


# IAM

resource "aws_iam_role" "role" {
  name               = "${var.stack}role-for-restapi-lookup-lambda"
  assume_role_policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
POLICY
}


# API Gateway - API Key related

resource "aws_api_gateway_api_key" "restapi" {
  name    = "${var.stack}api-key"
  enabled = "true"
  value   = "TBD-REPLACE-THIS-WITH-SOMETHING-ELSE"
}

resource "aws_api_gateway_deployment" "restapi" {
  rest_api_id = aws_api_gateway_rest_api.restapi.id

  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.restapi.body))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "restapi-dev" {
  deployment_id = aws_api_gateway_deployment.restapi.id
  rest_api_id   = aws_api_gateway_rest_api.restapi.id
  stage_name    = "dev"
}

resource "aws_api_gateway_usage_plan" "restapi-basic-usage-plan" {
  name         = "restapi-basic-usage-plan"
  description  = "TBD-SOME-DESCRIPTION"
  product_code = "TBD-SOME-PRODUCT-CODE"

  api_stages {
    api_id = aws_api_gateway_rest_api.restapi.id
    stage  = aws_api_gateway_stage.restapi-dev.stage_name
  }

  quota_settings {
    limit  = 1000
    offset = 0
    period = "DAY"
  }

  throttle_settings {
    burst_limit = 5
    rate_limit  = 10
  }
}

resource "aws_api_gateway_usage_plan_key" "restapi-basic-usage-plan-key" {
  key_id        = aws_api_gateway_api_key.restapi.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.restapi-basic-usage-plan.id
}


# API Gateway - Custom Domain

resource "aws_acm_certificate_validation" "certificate-api" {
  count = var.domain-certificate-arn == "" ? 0 : 1

  certificate_arn = var.domain-certificate-arn
}

resource "aws_api_gateway_domain_name" "restapi" {
  count = var.domain-name == "" ? 0 : 1

  domain_name              = var.domain-name
  regional_certificate_arn = aws_acm_certificate_validation.certificate-api[count.index].certificate_arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_base_path_mapping" "restapi" {
  count = var.domain-name == "" ? 0 : 1

  api_id      = aws_api_gateway_rest_api.restapi[count.index].id
  stage_name  = aws_api_gateway_stage.restapi-dev.stage_name
  domain_name = aws_api_gateway_domain_name.restapi[count.index].domain_name
  base_path   = ""
}

output "api-gateway-endpoint-lookup-base-url" {
  value = aws_api_gateway_deployment.restapi.invoke_url
}