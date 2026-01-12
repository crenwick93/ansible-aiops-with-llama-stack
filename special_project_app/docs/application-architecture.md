# Application Architecture

## 1. Scope

This page describes the logical and physical architecture of the Special Payment Project application, including its namespaces, services and main runtime flows.

## 2. Namespaces

### 2.1 special-payment-project

Primary application namespace. Contains:

- Web frontend
- Checkout API
- DNS alias for the payment gateway

Intended to represent the product/application team boundary.

### 2.2 payments-provider-sim

Simulated payment provider namespace. Contains:

- Internal payment gateway “sandbox” service

Intended to represent either:

- An external payment provider (e.g. Stripe / Adyen), or
- A separate internal payments/gateway team.

## 3. Core Components

### 3.1 checkout-frontend

- Type: Deployment + ClusterIP Service  
- Namespace: `special-payment-project`  
- Port: 8080

Responsibilities:

- Serve the checkout user interface
- Call `checkout-api` for `/api/checkout` operations

### 3.2 checkout-api

- Type: Deployment + ClusterIP Service  
- Namespace: `special-payment-project`  
- Port: 8000  
- Technology: FastAPI

Responsibilities:

- Validate and process checkout requests
- Interact with the internal payment gateway endpoint
- Map gateway responses to simple success/failure responses for the frontend

Key configuration:

- `PAYMENTS_BASE` (or similarly named variable) that defines the base URL for the payment gateway.
  - In typical setups this points to the in-cluster DNS alias:
    - `http://card-gateway-dns:5678`

### 3.3 card-gateway-dns

- Type: Service (`spec.type: ExternalName`)  
- Namespace: `special-payment-project`  
- Logical Port: 5678 (for documentation consistency)

Responsibilities:

- Provide a stable in-cluster hostname for the payment gateway
- Act as a DNS alias between `checkout-api` and the actual gateway implementation

Expected ExternalName target (canonical value):

- The canonical target FQDN is documented in  
  “Special Payment Project – Networking & External Dependencies”, section 4.2 Canonical target FQDN.

This allows the payment gateway implementation or location to change without modifying `checkout-api` code, as long as `card-gateway-dns` continues to point to the correct FQDN.

### 3.4 card-gateway-sandbox

- Type: Deployment + ClusterIP Service  
- Namespace: `payments-provider-sim`  
- Port: 5678

Responsibilities:

- Simulate a card gateway / processor
- Return deterministic responses (usually HTTP 200 with a simple body) for successful calls

## 4. Request Flow

### 4.1 Happy Path

1. User opens:  
   `https://special-payment.<apps-domain>`
2. OpenShift Route forwards traffic to `checkout-frontend`.
3. `checkout-frontend` triggers a call to `checkout-api` at `/api/checkout`.
4. `checkout-api`:
   - Builds the gateway URL from `PAYMENTS_BASE` (typically `http://card-gateway-dns:5678`).
   - Sends an HTTP request to `card-gateway-dns`.
5. `card-gateway-dns`:
   - Resolves via cluster DNS to the configured `externalName` target  
     (canonical value documented in Networking & External Dependencies, section 4.2 Canonical target FQDN).
6. `card-gateway-sandbox`:
   - Processes the request and returns 200 OK (or a simulated error).
7. `checkout-api` returns a 2xx response to the frontend.
8. `checkout-frontend` shows a success message.





