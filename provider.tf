provider "google" {
  project     = "ganesh-project-469710"
  credentials = file("gcp.json")
  region  = "us-central1"
  zone    = "us-central1-a"
}
