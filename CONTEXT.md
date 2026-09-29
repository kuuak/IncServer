# IncServer

The production host for the delivery-order-app: one shared server that runs every live Tenant's Environments side by side.

## Language

**Tenant**:
One customer business (a pizzeria) running its own instance of the delivery-order-app, with its own domain, data and credentials.
_Avoid_: Client, customer, vhost

**Environment**:
One running instance of a Tenant's app, either production or staging, with its own domain, database and identity; nothing is shared between two Environments, not even of the same Tenant.
_Avoid_: Stage, instance, site

**Live Tenant**:
A Tenant whose production Environment serves real orders from this host. Currently Peperoncini, with Tomate to be moved here from another host.

**Decommissioned Tenant**:
A former Tenant that no longer trades; only a final backup of its data is kept, and nothing of it runs or remains reachable on the host. Currently Dolce Vita (out of business since 2026-05).
_Avoid_: Paused, inactive
