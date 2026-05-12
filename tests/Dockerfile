FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive

# policy-rc.d prevents apt from auto-starting services (no init in container).
RUN echo "exit 101" > /usr/sbin/policy-rc.d && chmod +x /usr/sbin/policy-rc.d && \
    apt-get update -qq && \
    apt-get install -y -qq --no-install-recommends \
        apache2 nginx curl python3 openssl ca-certificates iproute2 procps && \
    apt-get clean && rm -rf /var/lib/apt/lists/* && \
    rm /usr/sbin/policy-rc.d

CMD ["sleep", "infinity"]
