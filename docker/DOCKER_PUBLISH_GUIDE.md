# Publishing the lbm-eval Docker Image

## Prerequisites

1. **Docker Hub access**: Ask TRI's IT team to add your Docker Hub account to the `toyotaresearch` organization. Without this, you won't be able to push images.

2. **Docker installed** and running on your machine.

3. **Log in to Docker Hub**:
   ```bash
   docker login
   ```

## Clone the repository

```bash
git clone https://github.com/jmercat/lbm_eval.git
cd lbm_eval
```

## Build and push

Run the publish script:

```bash
python docker/publish_to_dockerhub.py
```

This builds the image and pushes it as `toyotaresearch/lbm-eval-oss:vla-foundry`.

### Options

```bash
# Custom tag
python docker/publish_to_dockerhub.py --tag my-tag

# Skip build (if image is already built locally)
python docker/publish_to_dockerhub.py --skip-build
```

## Pull the image

Once published, anyone can pull it with:

```bash
docker pull toyotaresearch/lbm-eval-oss:vla-foundry
```
