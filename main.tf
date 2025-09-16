# Define the Google Cloud provider and project settings.
provider "google" {
  project = "nimble-augury-465911-f3"
   
  
}


# 1. Network and Firewall Rules

resource "google_compute_network" "web_app_network" {
  name                    = "web-app-network"
  auto_create_subnetworks = true
}

# Allow traffic from the Google Cloud Load Balancer and Health Checkers.
# This single rule replaces the two previous ones for better security and clarity.
resource "google_compute_firewall" "allow_lb_traffic" {
  name    = "allow-lb-and-health-check"
  network = google_compute_network.web_app_network.name

  allow {
    protocol = "tcp"
    ports    = ["80", "8085"]
  }

  # These source ranges are used by Google for both health checks and forwarding traffic.
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["web-server"]
}

# 2. Instance Template & Health Check

# Health check for the MIG.
resource "google_compute_health_check" "http_health_check" {
  name               = "http-health-check"
  timeout_sec        = 5
  check_interval_sec = 5
  http_health_check {
    port = 8085
  }
}

# Instance template defining the VM configuration and startup script.
resource "google_compute_instance_template" "web_app_template" {
  name_prefix  = "web-app-99template"
  machine_type = "e2-medium"
  tags         = ["web-server"]
  disk {
    source_image = "centos-stream-9"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network = google_compute_network.web_app_network.name
    # FIX: Added access_config to give VMs an external IP for package installation.
    access_config {
      // An empty block assigns an ephemeral public IP.
    }
  }

 labels = {
   "label1" = "java"
 }

metadata = {
  startup-script = <<-EOT
    #!/bin/bash
    
    # Get the private IP address (more reliable than hostname -i)
    HOSTKEY=$(hostname -I | awk '{print $1}' || echo "unknown")
    
    echo "Detected host IP: $HOSTKEY"
    
    # Trigger Harness pipeline with the IP
    response=$(curl -s -w "\n%%{http_code}" -X POST \
      -H 'content-type: application/json' \
      --url 'https://app.harness.io/gateway/pipeline/api/webhook/custom/LK-U8_s-R6u5Nb-AVr5ysw/v3?accountIdentifier=ucHySz2jQKKWQweZdXyCog&orgIdentifier=default&projectIdentifier=SFTY_Training&pipelineIdentifier=cdmigtriggeransibleganesh&triggerIdentifier=custom_host_ip' \
      -d '{"host": "'"$HOSTKEY"'"}')
    
    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | sed '$d')
    
    echo "Harness API response: $http_code"
    echo "Response body: $response_body"
    
    if [ "$http_code" -eq 200 ]; then
        echo "Successfully triggered pipeline with IP: $HOSTKEY"
    else
        echo "Failed to trigger pipeline. HTTP code: $http_code"
        exit 1
    fi
  EOT
}

  lifecycle {
    create_before_destroy = true
    ignore_changes = [ target_size ]
  }
}

# 3. Managed Instance Group (MIG)

resource "google_compute_instance_group_manager" "web_app_mig" {
  name               = "web-app-mig"
  base_instance_name = "web-app"
  zone               = "us-central1-a"
  target_size        = 2 # The desired number of instances.

  # Link the instance template to the MIG.
  version {
    instance_template = google_compute_instance_template.web_app_template.self_link
  }

  named_port {
    name = "http"
    port = 8085
  }

  # Define the rolling update policy.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_surge_fixed       = 1 # One new instance is created before an old one is terminated.
    max_unavailable_fixed = 0 # No instances can be taken offline.
  }

  # Enable auto-healing based on the health check.
  auto_healing_policies {
    health_check      = google_compute_health_check.http_health_check.self_link
    initial_delay_sec = 600
  }
}
# autoscale
resource "google_compute_autoscaler" "web_app_autoscaler" {
  name   = "web-app-autoscaler"
  zone   = "us-central1-a"
  target = google_compute_instance_group_manager.web_app_mig.self_link

  autoscaling_policy {
    max_replicas    = 3  # Maximum instances
    min_replicas    = 2  # Minimum instances
    cooldown_period = 60 # Cool-down period in seconds

    # CPU utilization target (adjust as needed)
    cpu_utilization {
      target = 0.6 # Scale when CPU utilization reaches 60%
    }
  }
}


# 4. HTTP Load Balancer

# Backend service to manage the MIG.
resource "google_compute_backend_service" "web_app_backend_service" {
  name        = "web-app-backend-service"
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 50
  health_checks = [
    google_compute_health_check.http_health_check.self_link
  ]
  backend {
    group = google_compute_instance_group_manager.web_app_mig.instance_group
  }
}

# URL map to route traffic to the backend service.
resource "google_compute_url_map" "web_app_url_map" {
  name            = "web-app-url-map"
  default_service = google_compute_backend_service.web_app_backend_service.self_link
}

# Target HTTP proxy to handle incoming requests.
resource "google_compute_target_http_proxy" "web_app_http_proxy" {
  name    = "web-app-http-proxy"
  url_map = google_compute_url_map.web_app_url_map.self_link
}

# Global forwarding rule to expose the load balancer on a public IP.
resource "google_compute_global_forwarding_rule" "web_app_forwarding_rule" {
  name       = "web-app-http-rule"
  target     = google_compute_target_http_proxy.web_app_http_proxy.self_link
  port_range = "80"
}

# 5. Output the load balancer's public IP address.
output "load_balancer_ip" {
  description = "The public IP address of the HTTP Load Balancer."
  value       = google_compute_global_forwarding_rule.web_app_forwarding_rule.ip_address
}



