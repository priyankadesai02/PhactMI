provider "aws" {
  shared_credentials_file = "${var.credentials_filepath}"
  region = "${var.region}"
}
resource "aws_vpc" "demovpc" {
    cidr_block = "10.0.0.0/16"
}

resource "aws_security_group" "demosg" {
  name        = "demosg"
  description = "Demo security group for AWS lambda and AWS RDS connection"
  vpc_id      = "${aws_vpc.demovpc.id}"
  ingress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["127.0.0.1/32"]
    self = true
  }
  egress {
    from_port       = 0
    to_port         = 0
    protocol        = "-1"
    cidr_blocks     = ["0.0.0.0/0"]
  }
}

resource "aws_subnet" "demo_subnet1" {
  vpc_id     = "${aws_vpc.demovpc.id}"
  cidr_block = "10.0.1.0/24"
  availability_zone = "${var.region}a"
}

resource "aws_subnet" "demo_subnet2" {
  vpc_id     = "${aws_vpc.demovpc.id}"
  cidr_block = "10.0.2.0/24"
  availability_zone = "${var.region}b"
}
resource "aws_subnet" "demo_subnet3" {
  vpc_id     = "${aws_vpc.demovpc.id}"
  cidr_block = "10.0.3.0/24"
  availability_zone = "${var.region}c"
}
resource "aws_db_subnet_group" "demo_dbsubnet" {
  name       = "main"
  subnet_ids = ["${aws_subnet.demo_subnet1.id}", "${aws_subnet.demo_subnet2.id}", "${aws_subnet.demo_subnet3.id}"]

  tags {
    Name = "My DB subnet group"
  }
}
resource "aws_db_instance" "MysqlForLambda" {
  identifier	       = "rdsinstance"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  instance_class       = "db.t2.micro"
  name                 = "ExampleDB"
  username             = "dbmaster"
  password             = "Pass1234"
  db_subnet_group_name = "${aws_db_subnet_group.demo_dbsubnet.id}"
  vpc_security_group_ids = ["${list("${aws_security_group.demosg.id}")}"]
  final_snapshot_identifier = "someid"
  skip_final_snapshot  = true
}
data "archive_file" "lambda" {
  type = "zip"
  source_dir ="lambda"
  output_path = "app.zip"
}
resource "aws_iam_role" "lambda_role" {
  name = "lambda-vpc-execution-role"
  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}
resource "aws_iam_role_policy_attachment" "test-attach" {
    role       = "${aws_iam_role.lambda_role.name}"
    policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_lambda_function" "test_lambda" {
  filename         = "app.zip"
  function_name    = "AWSLambdaExecutionCounter"
  role             = "${aws_iam_role.lambda_role.arn}"
  handler          = "app.handler"
  runtime          = "python3.6"
  source_code_hash = "${base64sha256(file("${data.archive_file.lambda.output_path}"))}"
  vpc_config {
      subnet_ids = ["${aws_subnet.demo_subnet1.id}", "${aws_subnet.demo_subnet2.id}", "${aws_subnet.demo_subnet3.id}"]
      security_group_ids = ["${list("${aws_security_group.demosg.id}")}"]
  }
  environment {
    variables = {
      rds_endpoint = "${aws_db_instance.MysqlForLambda.endpoint}"
    }
  }
}
resource "aws_api_gateway_rest_api" "MyDemoAPI" {
  name        = "MyDemoAPI"
  description = "This is my API for demonstration purposes"
}
resource "aws_api_gateway_resource" "MyDemoResource" {
  rest_api_id = "${aws_api_gateway_rest_api.MyDemoAPI.id}"
  parent_id   = "${aws_api_gateway_rest_api.MyDemoAPI.root_resource_id}"
  path_part   = "mydemoresource"
}
resource "aws_api_gateway_method" "MyDemoMethod" {
  rest_api_id   = "${aws_api_gateway_rest_api.MyDemoAPI.id}"
  resource_id   = "${aws_api_gateway_resource.MyDemoResource.id}"
  http_method   = "ANY"
  authorization = "NONE"
}
resource "aws_api_gateway_integration" "integration" {
  rest_api_id             = "${aws_api_gateway_rest_api.MyDemoAPI.id}"
  resource_id             = "${aws_api_gateway_resource.MyDemoResource.id}"
  http_method             = "${aws_api_gateway_method.MyDemoMethod.http_method}"
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = "arn:aws:apigateway:us-west-2:lambda:path/2015-03-31/functions/${aws_lambda_function.test_lambda.arn}/invocations"
}
resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = "${aws_lambda_function.test_lambda.arn}"
  principal     = "apigateway.amazonaws.com"
  source_arn = "arn:aws:execute-api:us-west-2:${var.account_id}:${aws_api_gateway_rest_api.MyDemoAPI.id}/*/${aws_api_gateway_method.MyDemoMethod.http_method}${aws_api_gateway_resource.MyDemoResource.path}"
}
resource "aws_api_gateway_deployment" "dev" {
  depends_on = ["aws_api_gateway_integration.integration"]
  rest_api_id = "${aws_api_gateway_rest_api.MyDemoAPI.id}"
  stage_name = "dev"
}
