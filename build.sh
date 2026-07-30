#!/usr/bin/env bash
set -euo pipefail

SECONDS=0

# Anchor to this script's repository root, not the caller's working directory.
REPO_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
cd "${REPO_ROOT}"

readonly DEFCONFIG="arch/arm64/configs/surya_defconfig"
readonly CLANG_ARCHIVE="clang-13289611-linux-x86.tar.xz"
readonly CLANG_URL="https://github.com/Impqxr/aosp_clang_ci/releases/download/13289611/${CLANG_ARCHIVE}"
readonly CLANG_SHA256="0a1fbf7f990122a63a2f8b9d6ddce458bebfb1bbe1c9efe8f1b58a2a3814ae7c"
readonly CLANG_BINARY_SHA256="2dc97e5225642abce70b8b077f7fae70b8006d53d9659008b5eb916814bf2ceb"
readonly ANYKERNEL_URL="https://github.com/Cilok-LAB/AK3-Surya.git"
readonly ANYKERNEL_COMMIT="b5ce992ec2e2f85eaa3b0724fd6b63d8e4dc1352"
readonly ANYKERNEL_BANNER="packaging/banner"
readonly EXPECTED_ORIGIN="git@github.com:willtanoe/android_kernel_xiaomi_surya.git"
readonly EXPECTED_BRANCH="avalanche"

ROOT_VARIANT="${1:-}"
BUILD_DATE="${2:-$(TZ=Asia/Jakarta date +%Y%m%d%H%M)}"
ARTIFACT_DIR="${3:-${REPO_ROOT}/artifacts}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc --all)}"

readonly KERNEL_PATH="${REPO_ROOT}/out/arch/arm64/boot"
readonly KERNEL_NAME="Avalanche-${ROOT_VARIANT}-${BUILD_DATE}.zip"

error() {
	echo "$*" >&2
}

die() {
	error "$*"
	exit 1
}

require_command() {
	local cmd
	for cmd; do
		command -v "${cmd}" >/dev/null 2>&1 || die "Required tool not found: ${cmd}"
	done
}

validate_repo_identity() {
	local origin_url branch
	origin_url="$(git remote get-url origin 2>/dev/null || true)"
	case "${origin_url}" in
		"${EXPECTED_ORIGIN}" | "https://github.com/willtanoe/android_kernel_xiaomi_surya" | "https://github.com/willtanoe/android_kernel_xiaomi_surya.git") ;;
		*) die "Repository identity mismatch: origin is '${origin_url}', expected '${EXPECTED_ORIGIN}' or its HTTPS equivalent" ;;
	esac

	branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
	if [[ "${branch}" != "${EXPECTED_BRANCH}" ]]; then
		die "Branch mismatch: currently on '${branch}', expected '${EXPECTED_BRANCH}'"
	fi
}

validate_inputs() {
	if [[ $# -lt 1 || $# -gt 3 ]]; then
		die "Usage: $0 <KSU|NoKSU> [build-date] [artifact-directory]"
	fi

	case "${ROOT_VARIANT}" in
		KSU | NoKSU) ;;
		*) die "Invalid variant '${ROOT_VARIANT}'. Use KSU or NoKSU." ;;
	esac

	if [[ -z "${BUILD_DATE}" || ! "${BUILD_DATE}" =~ ^[0-9]{12}$ ]]; then
		die "Invalid build date '${BUILD_DATE}'. Expected 12-digit YYYYMMDDHHMM."
	fi

	# Validate that the date is calendar-plausible (date will fail on e.g. 202613011200).
	TZ=Asia/Jakarta date -d "${BUILD_DATE:0:4}-${BUILD_DATE:4:2}-${BUILD_DATE:6:2} ${BUILD_DATE:8:2}:${BUILD_DATE:10:2}" >/dev/null \
		|| die "Invalid build date '${BUILD_DATE}': not a real calendar date."

	if [[ -z "${BUILD_JOBS}" || ! "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]]; then
		die "Invalid BUILD_JOBS '${BUILD_JOBS}'. Expected a positive integer."
	fi

	# Resolve artifact directory before any destructive work. Reject placing
	# artifacts inside the volatile out/ tree so a later rm -rf out does not
	# delete published packages.
	mkdir -p "${ARTIFACT_DIR}"
	ARTIFACT_DIR="$(realpath "${ARTIFACT_DIR}")"
	if [[ "${ARTIFACT_DIR}" == "${REPO_ROOT}/out"* ]]; then
		die "Artifact directory must not be inside ${REPO_ROOT}/out"
	fi
	readonly OUTPUT_ZIP="${ARTIFACT_DIR}/${KERNEL_NAME}"

	validate_repo_identity

	if [[ ! -f "${DEFCONFIG}" ]]; then
		die "Missing defconfig: ${DEFCONFIG}"
	fi
	if [[ ! -f "${ANYKERNEL_BANNER}" ]]; then
		die "Missing packaging banner: ${ANYKERNEL_BANNER}"
	fi
	if [[ ! -f "README.md" ]]; then
		die "Missing README.md"
	fi
}

setup_toolchain() {
	if [[ -x clang/bin/clang ]]; then
		printf '%s  %s\n' "${CLANG_BINARY_SHA256}" clang/bin/clang | sha256sum --check --strict
		return
	fi

	wget -c "${CLANG_URL}" -O "${CLANG_ARCHIVE}"
	printf '%s  %s\n' "${CLANG_SHA256}" "${CLANG_ARCHIVE}" | sha256sum --check --strict

	rm -rf clang.extract
	mkdir -p clang clang.extract
	tar -xf "${CLANG_ARCHIVE}" -C clang.extract
	if compgen -G 'clang.extract/clang-*' >/dev/null; then
		cp -a clang.extract/clang-*/. clang/
	else
		cp -a clang.extract/. clang/
	fi
	rm -rf clang.extract
	printf '%s  %s\n' "${CLANG_BINARY_SHA256}" clang/bin/clang | sha256sum --check --strict
}

configure_kernel() {
	rm -rf out
	mkdir -p out

	make O=out ARCH=arm64 surya_defconfig
	if [[ "${ROOT_VARIANT}" == "KSU" ]]; then
		scripts/config --file out/.config --enable KSU
	else
		scripts/config --file out/.config --disable KSU
	fi
	make O=out ARCH=arm64 olddefconfig
	python3 scripts/check-resolved-defconfig.py "${DEFCONFIG}" out/.config \
		--variant "${ROOT_VARIANT}"
}

compile_kernel() {
	export PATH="${REPO_ROOT}/clang/bin:${PATH}"
	export CCACHE_DIR="${CCACHE_DIR:-${HOME}/.cache/ccache}"
	export KBUILD_BUILD_HOST="builder"
	export KBUILD_BUILD_USER="willtanoe"
	export KBUILD_BUILD_VERSION=1
	export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
	export KBUILD_BUILD_TIMESTAMP="$(git show -s --format=%cD HEAD)"

	ccache --max-size "${CCACHE_MAXSIZE:-10G}"
	configure_kernel
	make -j"${BUILD_JOBS}" O=out ARCH=arm64 \
		CC="ccache clang" LD=ld.lld AS=llvm-as AR=llvm-ar NM=llvm-nm \
		OBJCOPY=llvm-objcopy OBJDUMP=llvm-objdump STRIP=llvm-strip \
		CROSS_COMPILE=aarch64-linux-gnu- \
		CROSS_COMPILE_COMPAT=arm-linux-gnueabi- LLVM=1 LLVM_IAS=1
}

validate_variant() {
	if [[ "${ROOT_VARIANT}" == "KSU" ]]; then
		grep -qx 'CONFIG_KSU=y' out/.config || {
			echo "KSU validation failed: CONFIG_KSU is not enabled" >&2
			exit 1
		}
	else
		grep -qx '# CONFIG_KSU is not set' out/.config || {
			echo "NoKSU validation failed: CONFIG_KSU is not disabled" >&2
			exit 1
		}
		if grep -Eq '[[:space:]](ksu_|kernelsu_|apply_kernelsu_)' out/System.map; then
			echo "NoKSU validation failed: KernelSU symbols are present" >&2
			exit 1
		fi
	fi
}

package_kernel() {
	local file
	for file in Image Image.gz dtb.img dtbo.img; do
		if [[ ! -f "${KERNEL_PATH}/${file}" ]]; then
			echo "Missing kernel output: ${KERNEL_PATH}/${file}" >&2
			exit 1
		fi
	done

	rm -rf out/anykernel
	mkdir -p out/anykernel
	git -C out/anykernel init --quiet
	git -C out/anykernel remote add origin "${ANYKERNEL_URL}"
	git -C out/anykernel fetch --quiet --depth=1 origin "${ANYKERNEL_COMMIT}"
	git -C out/anykernel checkout --quiet --detach FETCH_HEAD

	grep -qx 'kernel.string=OSS Kernel | POCO X3 NFC' out/anykernel/anykernel.sh || {
		echo "Unexpected AnyKernel metadata; refusing an unreviewed package" >&2
		exit 1
	}
	sed -i "s#^kernel.string=.*#kernel.string=Avalanche ${ROOT_VARIANT} | POCO X3 NFC#" \
		out/anykernel/anykernel.sh
	sed -i '/^device\.name2=karna$/d' out/anykernel/anykernel.sh
	cp "${ANYKERNEL_BANNER}" out/anykernel/banner
	cp README.md out/anykernel/README.md

	if grep -IRniE 'rethinking|khayloaf|CilokG|OSS Kernel' out/anykernel; then
		echo "Legacy AnyKernel branding remains in the package" >&2
		exit 1
	fi
	if grep -q '^device\.name[0-9]=karna$' out/anykernel/anykernel.sh; then
		echo "Unsupported karna target remains in the package" >&2
		exit 1
	fi

	cp "${KERNEL_PATH}/dtb.img" out/anykernel/kernels/
	cp "${KERNEL_PATH}/dtbo.img" out/anykernel/kernels/
	cp "${KERNEL_PATH}/Image.gz" out/anykernel/kernels/
	rm -rf out/anykernel/.git
	rm -f "${OUTPUT_ZIP}"
	(
		cd out/anykernel
		zip -qr9 "${OUTPUT_ZIP}" .
	)
}

main() {
	require_command make python3 git zip wget sha256sum ccache realpath nproc date
	validate_inputs "$@"
	setup_toolchain
	compile_kernel
	validate_variant
	package_kernel

	sha256sum "${OUTPUT_ZIP}"
	ccache --show-stats
	echo "Completed in $((SECONDS / 60)) minute(s) and $((SECONDS % 60)) second(s)"
}

rm -f compile.log
main "$@" 2>&1 | tee compile.log
