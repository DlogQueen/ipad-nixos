# Nix derivation for gaster — checkm8 bootrom exploit tool
#
# gaster exploits the checkm8 vulnerability (CVE-2019-8900) in Apple A5-A11
# SoCs via USB DFU mode. It places the device in "pwned DFU" state, allowing
# unsigned code (pongoOS) to be loaded.
#
# Usage: sudo gaster pwn

{ lib
, stdenv
, fetchFromGitHub
, libusb1
, openssl
, xxd
}:

stdenv.mkDerivation {
  pname = "gaster";
  version = "unstable-2024-01-01";

  src = fetchFromGitHub {
    owner = "0x7ff";
    repo = "gaster";
    rev = "main";
    hash = "sha256-0000000000000000000000000000000000000000000=";
  };

  nativeBuildInputs = [ xxd ];
  buildInputs = [ libusb1 openssl ];

  buildPhase = ''
    runHook preBuild

    # Generate payload headers from binary blobs
    for f in payload_A9.bin payload_notA9.bin payload_notA9_armv7.bin \
             payload_handle_checkm8_request.bin payload_handle_checkm8_request_armv7.bin; do
      xxd -iC "$f" "''${f%.bin}.h"
    done

    # Build with libusb support (Linux)
    $CC -Wall -Wextra -Wpedantic -DHAVE_LIBUSB \
      gaster.c lzfse.c \
      -o gaster \
      -lusb-1.0 -lcrypto -Os

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 gaster $out/bin/gaster
    runHook postInstall
  '';

  meta = with lib; {
    description = "checkm8 (CVE-2019-8900) bootrom exploit tool for Apple A5-A11";
    homepage = "https://github.com/0x7ff/gaster";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
