locals {
  # Globally-unique bucket name requirement: include account ID
  frontend_bucket_name = "${var.project_name}-${var.environment}-frontend-${data.aws_caller_identity.current.account_id}"
  api_base_url         = aws_api_gateway_stage.dev.invoke_url
}

resource "aws_s3_bucket" "frontend" {
  bucket = lower(local.frontend_bucket_name)
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

# Required for public website access
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "frontend_public_read" {
  statement {
    sid     = "PublicReadGetObject"
    effect  = "Allow"
    actions = ["s3:GetObject"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    resources = ["${aws_s3_bucket.frontend.arn}/*"]
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_public_read.json

  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

# Upload static assets
resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  source       = "${path.module}/../frontend/index.html"
  content_type = "text/html"
  etag         = filemd5("${path.module}/../frontend/index.html")
}

resource "aws_s3_object" "styles" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "styles.css"
  source       = "${path.module}/../frontend/styles.css"
  content_type = "text/css"
  etag         = filemd5("${path.module}/../frontend/styles.css")
}

resource "aws_s3_object" "app" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "app.js"
  source       = "${path.module}/../frontend/app.js"
  content_type = "application/javascript"
  etag         = filemd5("${path.module}/../frontend/app.js")
}

# Generate config.js directly (no local_file; avoids Windows file timing issues)
resource "aws_s3_object" "config" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "config.js"
  content_type = "application/javascript"

  content = <<EOT
window.APP_CONFIG = {
  API_BASE_URL: "${local.api_base_url}"
};
EOT

  # Stable checksum based on content
  etag = md5(<<EOT
window.APP_CONFIG = {
  API_BASE_URL: "${local.api_base_url}"
};
EOT
  )
}
