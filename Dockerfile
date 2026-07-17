FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        python3 python3-pip python3-venv \
        git ca-certificates curl wget tini bash less vim sudo \
        htop tree jq ripgrep fd-find fzf tmux ncdu \
        unzip zip file man-db gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 from NodeSource
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Python deps for the server.
RUN python3 -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir 'quart>=0.19' 'hypercorn>=0.16' 'httpx>=0.27'
ENV PATH="/opt/venv/bin:$PATH"

# Install Pi coding agent globally
RUN npm install -g @earendil-works/pi-coding-agent

# Run as root inside the container. openhost launches containers under rootless
# podman with --cap-drop=ALL and --security-opt=no-new-privileges, so "root"
# inside is still mapped to an unprivileged host user.
ENV HOME=/root

WORKDIR /app
COPY server.py /app/server.py
COPY templates /app/templates
COPY static /app/static
COPY entrypoint.sh /app/entrypoint.sh
# Site rcfile: lives under /etc so $HOME (which we point at the persistent data
# dir at runtime) stays untouched and user edits to ~/.bashrc/~/.bash_profile
# survive image updates.
COPY workbench.sh /etc/profile.d/workbench.sh
RUN echo '[ -r /etc/profile.d/workbench.sh ] && . /etc/profile.d/workbench.sh' \
        >> /etc/bash.bashrc \
    && chmod +x /app/entrypoint.sh

WORKDIR /root

EXPOSE 5000
ENTRYPOINT ["/usr/bin/tini", "--", "/app/entrypoint.sh"]