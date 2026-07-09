resource "aws_s3_bucket" "s3bucket" {
    bucket = "treinoterraform-bucket-${terraform.workspace}" 

    tags = {
        Name = "treino-terraform-2026"
        Iac = true
        context = "${terraform.workspace}" 
    }

}