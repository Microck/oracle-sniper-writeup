# Oracle Cloud Free Tier Resource Exhaustion Bypass via Autonomous API Polling

**Date:** Jan 29, 2026
**Topic:** Cloud Automation, Anti-Fingerprinting, Resource Arbitration
**Classification:** Technical Procedure / Vulnerability Disclosure

## Subject

Oracle Cloud's "Out of host capacity" error (HTTP 500) for free-tier ARM instances (`VM.Standard.A1.Flex`) functions as a soft limit based on temporal resource contention rather than a hard account restriction. By implementing high-frequency, authenticated API polling coupled with identity-layer obfuscation (residential proxies and canvas fingerprint spoofing), users can exploit race conditions in the provisioning queue to secure maximum-spec instances (4 OCPUs, 24GB RAM) that are otherwise unavailable via the web console.

## The "Capacity" Lie

When a user attempts to create an ARM instance in a popular region (Ashburn, Frankfurt, Tokyo), the console almost invariably returns `500 Internal Server Error: Out of host capacity`.

This is **not** a hard denial. It is a temporal state.
*   **Reality**: Capacity opens up constantly as other tenancies are terminated or hardware is added.
*   **The Flaw**: The allocation logic is First-Come-First-Served (FCFS).
*   **The Exploit**: A human cannot click fast enough to catch the 3-second window when a slot opens. An automated script polling every 60 seconds *can*.

## Details

The exploitation technique relies on three distinct phases: **Identity Engineering** (to create the account), **Autonomous Sniping** (to provision resources), and **Stealth Access** (to maintain the account).

---

## Phase 1: Identity Engineering (The "Clean Room")

Before any automation can run, you must possess a valid OCI account. This is the hardest step due to **Oracle Adaptive Access Manager (OAAM)**.

### The Threat Model
OAAM aggregates data to generate a "Fraud Risk Score":
*   **Browser Fingerprint**: Canvas hash, AudioContext, WebGL renderer, Fonts.
*   **Network Reputation**: IP Quality Score, Datacenter vs. Residential, Geo-velocity.
*   **Payment Consistency**: BIN country vs. IP country.

### The Bypass Procedure

**Tools Required:**
1.  **Dolphin{anty}**: Anti-detect browser that spoofs hardware fingerprints.
2.  **Residential Proxy**: Rotating or Sticky residential IPs (not VPNs/Datacenter).
3.  **Payment Method**: Physical card (not virtual/prepaid) matching the proxy region.

**Steps:**
1.  **Profile Generation**: In Dolphin, create a new profile. Set OS to "Windows" or "Mac". The software generates unique, consistent noise for Canvas/WebGL to mimic a generic consumer device.
2.  **Network Alignment**: Purchase a residential proxy (e.g., from *Decodo* or similar providers). Configure it as a **Sticky Session** (10-30 mins).
    *   *Critical*: If the IP changes from Madrid to Barcelona during the credit card verification, the geo-velocity check fails -> Account Ban.
3.  **Execution**: Complete the signup flow inside this container. Do not use your regular Chrome/Firefox.
4.  **Verification**: Once the "Welcome to Oracle Cloud" email arrives, the identity is established.

---

## Phase 2: The Sniper (Technical Implementation)

This phase moves the battle from the browser to the API. We deploy a persistent python daemon on a local server (NAS/Raspberry Pi) to handle the race condition.

### 1. Environment Preparation

The attack runs on a low-power Linux host.

**Directory Structure:**
```bash
/home/microck/oracle-sniper/
├── main.py             # The logic core
├── setup_init.sh       # Process wrapper & monitoring
├── oci.env             # Secrets configuration
├── oci_config          # OCI SDK Config
├── oci_api_key.pem     # Your private API key
└── requirements.txt    # Dependencies
```

### 2. Authentication Setup (`oci_config`)

Bypass the GUI entirely. Generate an API Signing Key in the Oracle Console (User Settings -> API Keys).

**File: `oci_config`**
```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=xx:xx:xx...
key_file=/home/microck/oracle-sniper/account_ashburn/oci_api_key.pem
tenancy=ocid1.tenancy.oc1..aaaa...
region=us-ashburn-1
```

### 3. Attack Configuration (`oci.env`)

This file controls the sniper's targeting parameters.

**File: `oci.env`**
```bash
# Target Definition
OCI_COMPUTE_SHAPE=VM.Standard.A1.Flex
# Ubuntu 22.04 Aarch64 Image OCID (Region Specific!)
OCI_IMAGE_ID=ocid1.image.oc1.iad.aaaaaaaa... 
OCPUS=4
MEMORY_IN_GBS=24

# Network Targets
# Must pre-create a VCN and Subnet in the console!
OCI_SUBNET_ID=ocid1.subnet.oc1.iad.aaaaaaaa... 
ASSIGN_PUBLIC_IP=true

# Attack Frequency
# < 60s risks "TooManyRequests" (429) rate limiting
REQUEST_WAIT_TIME_SECS=60 

# Notification Channels
DISCORD_WEBHOOK=https://discord.com/api/webhooks/...
```

### 4. The Logic Core (`main.py`)

The script implements a specific state machine to handle Oracle's error codes.

**Key Logic: Error Handling**
Oracle returns specific codes when capacity is full. The script must distinguish between "Fatal Error" (Config wrong) and "Soft Error" (Try again).

```python
def handle_errors(command, data, log):
    # These are NOT failures. They are "Wait" signals.
    soft_errors = [
        "TooManyRequests", 
        "Out of host capacity", 
        "InternalError", 
        "Bad Gateway"
    ]
    
    if data["code"] in soft_errors:
        log.info(f"Soft limit hit: {data['code']}. Sleeping...")
        time.sleep(WAIT_TIME)
        return True # Retry allowed

    # Anything else is a real crash
    raise Exception(f"Fatal Error: {data}")
```

**Key Logic: The Launch Loop**
```python
def launch_instance():
    # Loop until success
    while not instance_exist_flag:
        try:
            compute_client.launch_instance(...)
            # If we get here, we won.
            send_discord_message("🎉 Sniped!")
            break
        except ServiceError as e:
            # Handle the 500/429 errors
            handle_errors(...)
```

### 5. Deployment

We use `nohup` (No Hang Up) to ensure the process survives SSH disconnection.

**Command:**
```bash
chmod +x setup_init.sh
./setup_init.sh
```

**Monitoring Logs:**
```bash
tail -f launch_instance.log
```
*Output (Normal Operation):*
```text
2026-01-25 22:11:03 - INFO - Command: launch_instance-- Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
2026-01-25 22:12:04 - INFO - Command: launch_instance-- Output: {'status': 500, 'code': 'InternalError', 'message': 'Out of host capacity.'}
```

---

## Phase 3: Stealth Access (Post-Exploitation)

Once the instance creates, accessing it carelessly will get you banned. If your "Identity" IP (Spain Proxy) created the account, but your "Access" IP (Home IP) logs in via SSH, Oracle links the two.

**The "Clean" Link:**
Do not SSH directly. Tunnel traffic through a neutral, trusted intermediary.

**Scenario:**
1.  **Trusted Host**: Existing `oracle-paris` instance (or any cheap VPS).
2.  **Target Host**: The new `oracle-ashburn` instance.

**SSH Config (`~/.ssh/config`):**
```bash
# 1. The Jump Host (The Mask)
Host oracle-paris
    HostName 141.145.xxx.xxx
    User ubuntu
    IdentityFile ~/.ssh/id_rsa_paris

# 2. The Target (Hidden behind Paris)
Host oracle-ashburn
    HostName 10.0.0.x                # Use Private IP if VPN'd, or Public IP
    User ubuntu
    ProxyJump oracle-paris           # <--- THE KEY
    IdentityFile ~/.ssh/id_rsa_ashburn
```

**Traffic Flow:**
`Home PC` -> (Encrypted) -> `Paris VPS` -> (Encrypted) -> `Ashburn Instance`

To Oracle's logs in Ashburn, the connection comes from the Paris IP, not your home IP.

---

## Evidence of Success

Retrieving logs from the NAS confirms the methodology works.

**File: `INSTANCE_CREATED`**
```text
Instance ID: ocid1.instance.oc1.iad.anuwcljt6jdfblacplxseahalwablmit2csfvgj3gx47n5npd23d5zwnuega
Display Name: ashburn-sniper-instance
Availability Domain: MnaY:US-ASHBURN-AD-1
Shape: VM.Standard.A1.Flex
State: PROVISIONING
```

The script successfully negotiated the race condition, provisioned the resource, and alerted the user via Discord.

## Recommendations

To mitigate this exhaustion and evasion technique, Cloud Providers should:

1.  **Implement Proof-of-Work (PoW)**: Require a computational puzzle (hashcash style) for `launch_instance` API calls on free-tier tenancies. This makes high-frequency polling computationally expensive for the attacker.
2.  **Link Billing to Access**: Correlate login/API IP addresses with billing geography post-creation, not just during signup.
3.  **Waitlist Queue**: Replace "first-come-first-served" 500 errors with a verified waitlist system for high-demand shapes.

## References

- [Oracle Cloud Infrastructure Python SDK](https://github.com/oracle/oci-python-sdk)
- [OAAM (Oracle Adaptive Access Manager) Documentation](https://docs.oracle.com/cd/E23943_01/doc.1111/e15740/oaam.htm)
- [Dolphin{anty} Anti-Detect Browser](https://anty.dolphin.ru.com)
