resource "aws_iam_openid_connect_provider" "openidgit" {
  url = "token OICD"

  client_id_list = [
    "sts",
  ]
  tags = { 
    IAC = "Trust"
  }

  thumbprint_list = ["cf23df2207d99a74fbe169e3eba035e633b65d94"]
}