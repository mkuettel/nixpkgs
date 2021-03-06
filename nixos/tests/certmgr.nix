{ system ? builtins.currentSystem }:

with import ../lib/testing.nix { inherit system; };
let
  mkSpec = { host, service ? null, action }: {
    inherit action;
    authority = {
      file = {
        group = "nobody";
        owner = "nobody";
        path = "/tmp/${host}-ca.pem";
      };
      label = "www_ca";
      profile = "three-month";
      remote = "localhost:8888";
    };
    certificate = {
      group = "nobody";
      owner = "nobody";
      path = "/tmp/${host}-cert.pem";
    };
    private_key = {
      group = "nobody";
      mode = "0600";
      owner = "nobody";
      path = "/tmp/${host}-key.pem";
    };
    request = {
      CN = host;
      hosts = [ host "www.${host}" ];
      key = {
        algo = "rsa";
        size = 2048;
      };
      names = [
        {
          C = "US";
          L = "San Francisco";
          O = "Example, LLC";
          ST = "CA";
        }
      ];
    };
    inherit service;
  };

  mkCertmgrTest = { svcManager, specs, testScript }: makeTest {
    name = "certmgr-" + svcManager;
    nodes = {
      machine = { config, lib, pkgs, ... }: {
        networking.firewall.allowedTCPPorts = with config.services; [ cfssl.port certmgr.metricsPort ];
        networking.extraHosts = "127.0.0.1 imp.example.org decl.example.org";

        services.cfssl.enable = true;
        systemd.services.cfssl.after = [ "cfssl-init.service" "networking.target" ];

        systemd.services.cfssl-init = {
          description = "Initialize the cfssl CA";
          wantedBy    = [ "multi-user.target" ];
          serviceConfig = {
            User             = "cfssl";
            Type             = "oneshot";
            WorkingDirectory = config.services.cfssl.dataDir;
          };
          script = ''
            ${pkgs.cfssl}/bin/cfssl genkey -initca ${pkgs.writeText "ca.json" (builtins.toJSON {
              hosts = [ "ca.example.com" ];
              key = {
                algo = "rsa"; size = 4096; };
                names = [
                  {
                    C = "US";
                    L = "San Francisco";
                    O = "Internet Widgets, LLC";
                    OU = "Certificate Authority";
                    ST = "California";
                  }
                ];
            })} | ${pkgs.cfssl}/bin/cfssljson -bare ca
          '';
        };

        services.nginx = {
          enable = true;
          virtualHosts = lib.mkMerge (map (host: {
            ${host} = {
              sslCertificate = "/tmp/${host}-cert.pem";
              sslCertificateKey = "/tmp/${host}-key.pem";
              extraConfig = ''
                ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
              '';
              onlySSL = true;
              serverName = host;
              root = pkgs.writeTextDir "index.html" "It works!";
            };
          }) [ "imp.example.org" "decl.example.org" ]);
        };

        systemd.services.nginx.wantedBy = lib.mkForce [];

        systemd.services.certmgr.after = [ "cfssl.service" ];
        services.certmgr = {
          enable = true;
          inherit svcManager;
          inherit specs;
        };

      };
    };
    inherit testScript;
  };
in
{
  systemd = mkCertmgrTest {
    svcManager = "systemd";
    specs = {
      decl = mkSpec { host = "decl.example.org"; service = "nginx"; action ="restart"; };
      imp = toString (pkgs.writeText "test.json" (builtins.toJSON (
        mkSpec { host = "imp.example.org"; service = "nginx"; action = "restart"; }
      )));
    };
    testScript = ''
      $machine->waitForUnit('cfssl.service');
      $machine->waitUntilSucceeds('ls /tmp/decl.example.org-ca.pem');
      $machine->waitUntilSucceeds('ls /tmp/decl.example.org-key.pem');
      $machine->waitUntilSucceeds('ls /tmp/decl.example.org-cert.pem');
      $machine->waitUntilSucceeds('ls /tmp/imp.example.org-ca.pem');
      $machine->waitUntilSucceeds('ls /tmp/imp.example.org-key.pem');
      $machine->waitUntilSucceeds('ls /tmp/imp.example.org-cert.pem');
      $machine->waitForUnit('nginx.service');
      $machine->succeed('[ "1" -lt "$(journalctl -u nginx | grep "Starting Nginx" | wc -l)" ]');
      $machine->succeed('curl --cacert /tmp/imp.example.org-ca.pem https://imp.example.org');
      $machine->succeed('curl --cacert /tmp/decl.example.org-ca.pem https://decl.example.org');
    '';
  };

  command = mkCertmgrTest {
    svcManager = "command";
    specs = {
      test = mkSpec { host = "command.example.org"; action = "touch /tmp/command.executed"; };
    };
    testScript = ''
      $machine->waitForUnit('cfssl.service');
      $machine->waitUntilSucceeds('stat /tmp/command.executed');
    '';
  };

}
