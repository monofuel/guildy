{
  description = "Nim development environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    libdave-src = {
      url = "github:discord/libdave";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, libdave-src }:
    let
      pkgs = nixpkgs.legacyPackages.x86_64-linux;

      # MLSPP (Cisco MLS C++ library) - not in nixpkgs
      # Pinned to the commit used by libdave's vcpkg overlay
      mlspp = pkgs.stdenv.mkDerivation {
        pname = "mlspp";
        version = "0.1-git";
        src = pkgs.fetchFromGitHub {
          owner = "cisco";
          repo = "mlspp";
          rev = "1cc50a124a3bc4e143a787ec934280dc70c1034d";
          hash = "sha256-IjS2yYnfScwJR3BqDJp37ANgNkCg9ECxON41tYEocvA=";
        };
        nativeBuildInputs = with pkgs; [ cmake pkg-config ];
        buildInputs = with pkgs; [ openssl nlohmann_json ];
        cmakeFlags = [
          "-DDISABLE_GREASE=ON"
          "-DMLS_CXX_NAMESPACE=mlspp"
          "-DTESTING=OFF"
        ];
      };

      # libdave (Discord Audio/Video E2EE) - not in nixpkgs
      libdave = pkgs.stdenv.mkDerivation {
        pname = "libdave";
        version = "1.0-local";
        src = libdave-src;
        sourceRoot = "source/cpp";
        nativeBuildInputs = with pkgs; [ cmake pkg-config ];
        buildInputs = [ pkgs.openssl pkgs.nlohmann_json mlspp ];
        cmakeFlags = [
          "-DBUILD_SHARED_LIBS=ON"
          "-DTESTING=OFF"
          "-DPERSISTENT_KEYS=OFF"
        ];
      };

    in {
      devShells.x86_64-linux.default = pkgs.mkShell {
        buildInputs = with pkgs; [
          nim
          nimble
          curlFull
          # Voice dependencies (used with -d:guildyVoice)
          libopus
          libsodium
          libdave
        ];

        shellHook = ''
          export LD_LIBRARY_PATH=${pkgs.curl.out}/lib:${libdave}/lib:${pkgs.libopus}/lib:${pkgs.libsodium}/lib:$LD_LIBRARY_PATH
        '';
      };
    };
}
