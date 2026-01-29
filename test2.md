# Oracle Cloud Free Tier Provisioning Fails To Rate-Limit API Polls, Allowing Resource Exhaustion via Autonomous Retries

The `launch_instance` API endpoint in Oracle Cloud Infrastructure (OCI) fails to enforce meaningful rate limits or queueing on free-tier allocation requests, allowing an unauthorized automation script to bypass "Out of host capacity" errors and monopolize hardware availability via high-frequency request flooding.

## Technical Analysis

The vulnerability lies in the handling of `500 Internal Server Error` and `429 Too Many Requests` responses within the instance provisioning lifecycle. Instead of enforcing a hard backoff or assigning requests to a FIFO queue, OCI returns a transient failure state that permits immediate retries.

The exploitation script (`main.py`) implements a state machine that treats these HTTP errors not as failures, but as `WAIT` signals.

```python
# main.py:280
def handle_errors(command, data, log):
    if "code" in data:
        if (data["code"] in ("TooManyRequests", "Out of host capacity.", 'InternalError')) \
                or (data["message"] in ("Out of host capacity.", "Bad Gateway")):
            # The vulnerability: Error is treated as a "pause" rather than a "stop"
            log.info("Command: %s--\nOutput: %s", command, data)
            time.sleep(WAIT_TIME)
            return True 
```

The `launch_instance` function wraps this logic in an infinite loop (`while not instance_exist_flag`), effectively performing a resource race condition attack against the provisioning controller. The script bypasses the UI's friction and continuously calls `compute_client.launch_instance(...)` until a `200 OK` is received.

```python
# main.py:434
while not instance_exist_flag:
    try:
        launch_instance_response = compute_client.launch_instance(...)
        if launch_instance_response.status == 200:
            instance_exist_flag = check_instance_state_and_write(...)
    except oci.exceptions.ServiceError as srv_err:
        # Retry logic invoked here
        handle_errors("launch_instance", data, logging_step5)
```

## The Attack Scenario (Alice, Bob, Mallory)

1. **Alice (Legitimate User)**: Logs into the OCI Console and manually clicks "Create Instance". The request involves UI rendering latency, CAPTCHA checks, and human reaction time.
2. **Mallory (Attacker)**: Deploys the headless `main.py` daemon. The script issues `launch_instance` calls continuously, ignoring "Out of host capacity" warnings.
3. **The Result**: When a hypervisor slot (`VM.Standard.A1.Flex`) is freed by the scheduler, Mallory's automated request occupies the slot within milliseconds of availability. Alice receives a `500 Out of host capacity` error, unaware that the capacity briefly existed but was instantaneously consumed by Mallory's automation.

## Impact & Mitigation

**Impact:** Legitimate users are effectively permanently denied service (Denial of Service). Attackers amass significant cloud compute resources (4 OCPUs, 24GB RAM per account) for $0.00, bypassing the intended equitable distribution of the Free Tier.

**Mitigation:** Implement a cryptographic Proof-of-Work (PoW) challenge (e.g., Hashcash) for `launch_instance` calls on Free Tier tenancies. This would make high-frequency polling computationally prohibitive for the attacker without significantly impacting legitimate, low-frequency users. Alternatively, replace the First-Come-First-Served (FCFS) mechanism with an asynchronous waitlist queue.
