# syntax=docker/dockerfile:1.6
FROM nvidia/cuda:12.6.3-cudnn-runtime-ubuntu24.04

ARG USERNAME=anzu
ARG UID=1000
ARG GID=1000
ARG LBM_EVAL_VERSION=1.1.0

ENV DEBIAN_FRONTEND=noninteractive
ENV ANZU_ROOT=/opt/anzu
ENV LBM_EVAL_HOME=/opt/lbm_eval
ENV LBM_EVAL_VENV=${LBM_EVAL_HOME}/.venv
ENV LBM_EVAL_VERSION=${LBM_EVAL_VERSION}

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Install system dependencies
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      git \
      gnupg \
      libgl1 \
      libglib2.0-0 \
      libegl1 \
      libxkbcommon0 \
      netcat-openbsd \
      openssh-client \
      procps \
      python3.12 \
      python3.12-venv \
      python3-pip \
      rsync \
      sudo \
      unzip \
      wget \
      xvfb \
      xauth && \
    rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip" && \
    unzip -q /tmp/awscliv2.zip -d /tmp && \
    /tmp/aws/install && \
    rm -rf /tmp/awscliv2.zip /tmp/aws

# Install uv
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    mv /root/.local/bin/uv /usr/local/bin/uv && \
    mv /root/.local/bin/uvx /usr/local/bin/uvx 2>/dev/null || true

# Create unprivileged user
RUN groupadd --gid "${GID}" "${USERNAME}" && \
    useradd --uid "${UID}" --gid "${GID}" --create-home --shell /bin/bash "${USERNAME}" && \
    echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

# Create installation directories
RUN install -d -m 0755 -o "${UID}" -g "${GID}" "${LBM_EVAL_HOME}" && \
    install -d -m 0755 -o "${UID}" -g "${GID}" "${ANZU_ROOT}" && \
    install -d -m 0755 -o "${UID}" -g "${GID}" "/opt/lbm" && \
    install -d -m 1777 "/tmp/lbm" "/tmp/lbm/rollouts" "/tmp/lbm/logs"

USER ${USERNAME}
WORKDIR ${LBM_EVAL_HOME}

# Create Python virtual environment
RUN python3.12 -m venv "${LBM_EVAL_VENV}"

# Upgrade pip
RUN "${LBM_EVAL_VENV}/bin/pip" install --upgrade pip wheel setuptools

# Install lbm_eval and robot_gym from repo source
COPY --chown=${UID}:${GID} pyproject.toml ${LBM_EVAL_HOME}/pyproject.toml
COPY --chown=${UID}:${GID} lbm_eval ${LBM_EVAL_HOME}/lbm_eval
COPY --chown=${UID}:${GID} robot_gym ${LBM_EVAL_HOME}/robot_gym
COPY --chown=${UID}:${GID} grpc_workspace ${LBM_EVAL_HOME}/grpc_workspace
COPY --chown=${UID}:${GID} anzu ${LBM_EVAL_HOME}/anzu
COPY --chown=${UID}:${GID} LICENSE-APACHE ${LBM_EVAL_HOME}/LICENSE-APACHE
COPY --chown=${UID}:${GID} LICENSE-MIT ${LBM_EVAL_HOME}/LICENSE-MIT
COPY --chown=${UID}:${GID} README.md ${LBM_EVAL_HOME}/README.md
COPY --chown=${UID}:${GID} TRAINING_DATA_FORMAT.md ${LBM_EVAL_HOME}/TRAINING_DATA_FORMAT.md
RUN "${LBM_EVAL_VENV}/bin/pip" install "${LBM_EVAL_HOME}"

# Download and install asset wheels (models + scenarios) from GitHub releases
RUN set -euxo pipefail; \
    "${LBM_EVAL_VENV}/bin/pip" install \
      "https://github.com/ToyotaResearchInstitute/lbm_eval/releases/download/${LBM_EVAL_VERSION}/lbm_eval_models-${LBM_EVAL_VERSION}-py3-none-any.whl" \
      "https://github.com/ToyotaResearchInstitute/lbm_eval/releases/download/${LBM_EVAL_VERSION}/lbm_eval_scenarios-${LBM_EVAL_VERSION}-py3-none-any.whl"

# Install policy_interfaces
COPY --chown=${UID}:${GID} docker/policy_interfaces /tmp/policy_interfaces
RUN "${LBM_EVAL_VENV}/bin/pip" install /tmp/policy_interfaces && \
    rm -rf /tmp/policy_interfaces

# Install ML dependencies (torch, diffusion policy, etc.)
RUN "${LBM_EVAL_VENV}/bin/pip" install \
    --find-links https://download.pytorch.org/whl/torch/ \
    --find-links https://download.pytorch.org/whl/torchvision/ \
    "torch==2.6.0+cu126" \
    "torchvision==0.21.0+cu126" \
    "torchdata==0.9.0" \
    "accelerate>=1.2.0" \
    "pytorch-lightning>=1.9.0" \
    einops \
    numba \
    scipy \
    "transformers==4.50.2" \
    "timm==0.9.10" \
    diffusers \
    hydra-core \
    wandb \
    dill \
    draccus \
    tensorboard \
    tensorboardx \
    huggingface_hub \
    "boto3[crt]" \
    jsonlines \
    rich \
    "zarr==2.17.0" \
    "numcodecs<0.16.0" \
    imagecodecs \
    "s3fs>=2024.2.0" \
    imageio \
    imageio-ffmpeg

# Set PATH to include venv binaries
ENV PATH="${LBM_EVAL_VENV}/bin:${PATH}"

# Add torch shared libraries to LD_LIBRARY_PATH
ENV LD_LIBRARY_PATH="${LBM_EVAL_VENV}/lib/python3.12/site-packages/torch/lib:${LD_LIBRARY_PATH:-}"

# Pre-cache Drake robot models so containers don't download ~50-100MB on every start
RUN python -c "from pydrake.all import PackageMap; PackageMap().GetPath('drake_models')"

# Copy scripts (as root for permissions, then switch back)
USER root

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/anzu-entrypoint.sh
COPY --chmod=755 docker/launch_sim.sh /usr/local/bin/launch_sim.sh
COPY --chmod=755 docker/run_inference_bundle.sh /usr/local/bin/run_inference_bundle.sh

# Copy to /opt/anzu for compatibility with vla_foundry paths
COPY --chmod=755 docker/launch_sim.sh ${ANZU_ROOT}/launch_sim.sh
COPY --chmod=755 docker/run_inference_bundle.sh ${ANZU_ROOT}/run_inference_bundle.sh
RUN chown ${UID}:${GID} ${ANZU_ROOT}/launch_sim.sh ${ANZU_ROOT}/run_inference_bundle.sh

# Also copy to LBM_EVAL_HOME
COPY --chmod=755 docker/launch_sim.sh ${LBM_EVAL_HOME}/launch_sim.sh
COPY --chmod=755 docker/run_inference_bundle.sh ${LBM_EVAL_HOME}/run_inference_bundle.sh
RUN chown ${UID}:${GID} ${LBM_EVAL_HOME}/launch_sim.sh ${LBM_EVAL_HOME}/run_inference_bundle.sh

# Create .aws directory for credentials mount
RUN mkdir -p /home/${USERNAME}/.aws && chown ${UID}:${GID} /home/${USERNAME}/.aws

# Create venv symlink in /opt/anzu for compatibility
RUN ln -s "${LBM_EVAL_VENV}" "${ANZU_ROOT}/venv"

ENV INFERENCE_WORKDIR=/opt/lbm

USER ${USERNAME}
WORKDIR ${ANZU_ROOT}

ENV LAUNCH_WORKDIR=${ANZU_ROOT}
ENV LAUNCH_SCRIPT=launch_sim.sh

ENTRYPOINT ["bash", "/usr/local/bin/anzu-entrypoint.sh"]
CMD ["bash"]
