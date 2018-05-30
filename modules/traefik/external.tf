###################################################################################################
# Traefik External Reverse Proxy
###################################################################################################

resource "aws_lb" "external" {
  name            = "${var.external_lb_name}"
  security_groups = ["${aws_security_group.external_lb.id}"]
  subnets         = ["${var.subnets}"]

  tags = "${var.tags}"
}

resource "aws_security_group" "external_lb" {
  name        = "${var.external_lb_name}-lb"
  description = "Security group for external load balancer for Traefik"
  vpc_id      = "${var.vpc_id}"

  tags = "${merge(var.tags, map("Name", format("%s-lb", var.external_lb_name)))}"
}

##########################
# Security Group Rules for LB
##########################

# _ -> External LB
resource "aws_security_group_rule" "external_lb_http_ingress" {
  type              = "ingress"
  from_port         = 80
  to_port           = 80
  protocol          = "tcp"
  cidr_blocks       = "${var.external_lb_incoming_cidr}"
  security_group_id = "${aws_security_group.external_lb.id}"
}

# _ -> External LB
resource "aws_security_group_rule" "external_lb_https_ingress" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = "${var.external_lb_incoming_cidr}"
  security_group_id = "${aws_security_group.external_lb.id}"
}

# External LB -> Traefik External endpoint
resource "aws_security_group_rule" "external_lb_http_egress" {
  type                     = "egress"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = "${var.nomad_clients_external_security_group}"
  security_group_id        = "${aws_security_group.external_lb.id}"
}

# External LB -> Traefik health check
resource "aws_security_group_rule" "external_lb_health_check_egress" {
  type                     = "egress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = "${var.nomad_clients_external_security_group}"
  security_group_id        = "${aws_security_group.external_lb.id}"
}

##########################
# Security Group Rules for Nomad Clients
##########################

# External LB -> Traefik External Endpoint
resource "aws_security_group_rule" "nomad_external_http_ingress" {
  type                     = "ingress"
  security_group_id        = "${var.nomad_clients_external_security_group}"
  from_port                = 80
  to_port                  = 80
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.external_lb.id}"
}

# External LB -> Traefik health check
resource "aws_security_group_rule" "nomad_external_health_check_ingress" {
  type                     = "ingress"
  security_group_id        = "${var.nomad_clients_external_security_group}"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = "${aws_security_group.external_lb.id}"
}

#####################
# Listeners and target group
#####################

resource "aws_lb_listener" "http_external" {
  load_balancer_arn = "${aws_lb.external.arn}"
  port              = "80"
  protocol          = "HTTP"

  default_action {
    target_group_arn = "${aws_lb_target_group.external.arn}"
    type             = "forward"
  }
}

resource "aws_lb_listener" "https_external" {
  load_balancer_arn = "${aws_lb.external.arn}"
  port              = "443"
  protocol          = "HTTPS"
  ssl_policy        = "${var.elb_ssl_policy}"
  certificate_arn   = "${var.external_certificate_arn}"

  default_action {
    target_group_arn = "${aws_lb_target_group.external.arn}"
    type             = "forward"
  }
}

resource "aws_lb_target_group" "external" {
  name                 = "${var.external_lb_name}-traefik"
  port                 = "80"
  protocol             = "HTTP"
  vpc_id               = "${var.vpc_id}"
  deregistration_delay = "${var.deregistration_delay}"

  health_check {
    healthy_threshold   = "5"
    matcher             = "200"
    timeout             = "5"
    unhealthy_threshold = "2"
    path                = "/ping"
    port                = "8080"
  }
}

resource "aws_autoscaling_attachment" "external" {
  autoscaling_group_name = "${var.external_nomad_clients_asg}"
  alb_target_group_arn   = "${aws_lb_target_group.external.arn}"
}

#############################
# Defines settings for Traefik Reverse Proxy
#############################

# DNS Record for the external Traefik listener domain.
# Everything else deployed should alias (recommended) or CNAME this domain
resource "aws_route53_record" "external_dns_record" {
  zone_id = "${data.aws_route53_zone.default.zone_id}"
  name    = "${var.traefik_external_base_domain}"
  type    = "A"

  alias {
    name                   = "${aws_lb.external.dns_name}"
    zone_id                = "${aws_lb.external.zone_id}"
    evaluate_target_health = false
  }
}