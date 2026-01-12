# Observability & Alerts

## 1. Overview

This page documents how the Special Payment Project is monitored and what alerts are configured. The goal is to quickly detect issues impacting the checkout experience.

## 2. Metrics

Prometheus is used to scrape metrics from:

- `checkout-api` (primary focus)
- Optionally `checkout-frontend` and `card-gateway-sandbox`

Typical metrics include:

- Request rates and latencies for `checkout-api`
- HTTP status code counts (2xx, 4xx, 5xx)
- Pod readiness and basic resource usage

## 3. Alerting

### 3.1 Example alert: CheckoutApiHighErrorRate

- Alert name: `CheckoutApiHighErrorRate`
- Triggered when: HTTP 5xx responses from `checkout-api` exceed a threshold for a sustained period.

Purpose:

- Detect scenarios where the UI appears up, but user checkout operations fail due to backend or upstream issues.

### 3.2 Alert routing

Alertmanager routes alerts to:

- Email / chat channels for on-call engineers
- A generic webhook endpoint for automation/orchestration tools (e.g. Ansible-based workflows or AIOps pipelines)

## 4. Logs

### 4.1 checkout-api logs

Include messages about outbound calls to the gateway URL (based on `PAYMENTS_BASE`).

Useful for spotting:

- Connection timeouts
- DNS resolution errors for `card-gateway-dns`
- Non-2xx responses from the gateway

### 4.2 checkout-frontend logs

Typically HTTP access logs and minimal runtime logging.

### 4.3 card-gateway-sandbox logs

Help confirm whether requests are reaching the simulated gateway at all.

## 5. Dashboards (if available)

Dashboards (Grafana or similar) may show:

- Request volume and error rate for `/api/checkout`
- Latency distributions
- Basic service health across namespaces

## 6. Typical Observability Patterns

When there is a payment path problem, common signals are:

- `CheckoutApiHighErrorRate` firing
- Increased proportion of HTTP 5xx for `checkout-api`
- `checkout-api` pods are Running/Ready (i.e. not obviously crashing)

Logs from `checkout-api` often show failures when calling whatever hostname is set in `PAYMENTS_BASE` (usually `card-gateway-dns`).


