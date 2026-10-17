{
  description = "Minimal SNTP + HTTP/JSON time server for syncing rover computes to a base station";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      forAllSystems = f: lib.genAttrs lib.systems.flakeExposed (system: f nixpkgs.legacyPackages.${system});
      cargoToml = lib.importTOML ./Cargo.toml;
    in
    {
      packages = forAllSystems (pkgs: rec {
        time-server = pkgs.rustPlatform.buildRustPackage {
          pname = cargoToml.package.name;
          version = cargoToml.package.version;
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./Cargo.toml
              ./Cargo.lock
              ./src
              ./get-date.sh
            ];
          };
          cargoLock.lockFile = ./Cargo.lock;

          nativeBuildInputs = [ pkgs.makeWrapper ];
          postInstall = ''
            install -Dm755 get-date.sh $out/bin/get-date.sh
            wrapProgram $out/bin/get-date.sh \
              --prefix PATH : ${lib.makeBinPath [ pkgs.bash pkgs.coreutils ]}
          '';

          meta = {
            description = "Minimal SNTP + HTTP/JSON time server";
            homepage = "https://github.com/dbreth/rs-local-time-server";
            mainProgram = "time-server";
            platforms = lib.platforms.unix;
          };
        };
        default = time-server;
      });

      apps = forAllSystems (pkgs: {
        default = {
          type = "app";
          program = lib.getExe self.packages.${pkgs.stdenv.hostPlatform.system}.time-server;
        };
        get-date = {
          type = "app";
          program = "${self.packages.${pkgs.stdenv.hostPlatform.system}.time-server}/bin/get-date.sh";
        };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            cargo
            rustc
            rustfmt
            clippy
          ];
        };
      });

      nixosModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.services.time-server;
          portOf = addr: lib.toInt (lib.last (lib.splitString ":" addr));
        in
        {
          options.services.time-server = {
            enable = lib.mkEnableOption "the ROAR SNTP + HTTP/JSON time server";
            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.time-server;
              defaultText = lib.literalExpression "time-server.packages.\${system}.time-server";
              description = "The time-server package to use.";
            };
            ntpAddress = lib.mkOption {
              type = lib.types.str;
              default = "0.0.0.0:123";
              description = "UDP address the SNTP server binds to.";
            };
            httpAddress = lib.mkOption {
              type = lib.types.str;
              default = "0.0.0.0:8123";
              description = "TCP address the HTTP/JSON endpoint (used by get-date.sh) binds to.";
            };
            openFirewall = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Open the NTP (UDP) and HTTP (TCP) ports in the firewall.";
            };
          };

          config = lib.mkIf cfg.enable {
            systemd.services.time-server = {
              description = "ROAR SNTP time server (reference clock for rover computes)";
              after = [ "network-online.target" ];
              wants = [ "network-online.target" ];
              wantedBy = [ "multi-user.target" ];
              serviceConfig = {
                ExecStart = "${lib.getExe cfg.package} ${cfg.ntpAddress} ${cfg.httpAddress}";
                Restart = "always";
                DynamicUser = true;
                AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
                CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
              };
            };

            networking.firewall = lib.mkIf cfg.openFirewall {
              allowedUDPPorts = [ (portOf cfg.ntpAddress) ];
              allowedTCPPorts = [ (portOf cfg.httpAddress) ];
            };
          };
        };
    };
}
