.PHONY: test verify verify-background check-background-test-safety verify-variants build-full build-app-store \
	build-intel build-apple-silicon build-universal

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
