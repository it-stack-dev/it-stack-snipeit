# Architecture — IT-Stack SNIPEIT

## Overview

Snipe-IT tracks all hardware assets, licenses, and accessories, integrated with GLPI CMDB and Odoo for procurement workflows.

## Role in IT-Stack

- **Category:** it-management
- **Phase:** 4
- **Server:** lab-mgmt1 (10.0.50.18)
- **Ports:** 80 (HTTP), 443 (HTTPS)

## Dependencies

| Dependency | Type | Required For |
|-----------|------|--------------|
| FreeIPA | Identity | User directory |
| Keycloak | SSO | Authentication |
| PostgreSQL | Database | Data persistence |
| Redis | Cache | Sessions/queues |
| Traefik | Proxy | HTTPS routing |

## Data Flow

```
User → Traefik (HTTPS) → snipeit → PostgreSQL (data)
                       ↗ Keycloak (auth)
                       ↗ Redis (sessions)
```

## Security

- All traffic over TLS via Traefik
- Authentication delegated to Keycloak OIDC
- Database credentials via Ansible Vault
- Logs shipped to Graylog
