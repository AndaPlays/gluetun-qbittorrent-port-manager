NAME = andaplays/gluetun-qbittorrent-port-manager
VERSION = $(shell cat version)

build: Dockerfile start.sh healthcheck.sh
	docker buildx build --platform linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64,linux/ppc64le \
		-t $(NAME):$(VERSION) -t $(NAME):latest --label "version=$(VERSION)" --load .

push: Dockerfile start.sh healthcheck.sh version .secret
	cat .secret | docker login -u andaplays --password-stdin
	docker buildx build --platform linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64,linux/ppc64le \
		-t $(NAME):$(VERSION) -t $(NAME):latest --label "version=$(VERSION)" --push .

dev-build: Dockerfile start.sh healthcheck.sh
	docker buildx build --platform linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64,linux/ppc64le \
		-t $(NAME):dev --label "version=$(VERSION)" --load .

dev-push: Dockerfile start.sh healthcheck.sh version .secret
	cat .secret | docker login -u andaplays --password-stdin
	docker buildx build --platform linux/386,linux/amd64,linux/arm/v6,linux/arm/v7,linux/arm64,linux/ppc64le \
		-t $(NAME):dev --label "version=$(VERSION)" --push .
