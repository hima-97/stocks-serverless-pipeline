// This will be overwritten by Terraform during deploy.
// Keep the shape: window.APP_CONFIG = { API_BASE_URL: "..." }
// It can stay as-is (with REPLACE_ME). Terraform will upload the real one to S3 anyway.
window.APP_CONFIG = {
  API_BASE_URL: "REPLACE_ME"
};
