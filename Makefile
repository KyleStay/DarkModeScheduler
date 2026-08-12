NOTARY_PROFILE ?= StayLevel

.PHONY: test verify verify-background check-background-test-safety verify-variants build-full build-app-store \
	build-intel build-apple-silicon build-universal \
	release release-intel release-apple-silicon release-universal release-local

test:
	./run-tests.sh

verify: test build-universal verify-variants verify-background

verify-background: check-background-test-safety
	Tools/verify-background.sh

check-background-test-safety:
	Tools/check-background-test-safety.sh

verify-variants:
	Tools/verify-variants.sh

build-full:
	DISTRIBUTION_CHANNEL=full ./build.sh

build-app-store:
	Tools/build-app-store.sh

build-intel:
	BUILD_ARCH=x86_64 ./build.sh

build-apple-silicon:
	BUILD_ARCH=arm64 ./build.sh

build-universal:
	BUILD_ARCH=universal ./build.sh

release:
	NOTARY_PROFILE="$(NOTARY_PROFILE)" ./release.sh

release-intel:
	NOTARY_PROFILE="$(NOTARY_PROFILE)" RELEASE_ARCHS=x86_64 ./release.sh

release-apple-silicon:
	NOTARY_PROFILE="$(NOTARY_PROFILE)" RELEASE_ARCHS=arm64 ./release.sh

release-universal:
	NOTARY_PROFILE="$(NOTARY_PROFILE)" RELEASE_ARCHS=universal ./release.sh

release-local:
	SKIP_NOTARIZE=1 ./release.sh
