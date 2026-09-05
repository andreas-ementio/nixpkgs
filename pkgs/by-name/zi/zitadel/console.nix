{
  generateProtobufCode,
  version,
  zitadelRepo,
}:

{
  stdenv,
  fetchPnpmDeps,
  nodejs,
  pnpm_10,
  pnpmBuildHook,
  pnpmConfigHook,

  grpc-gateway,
  protoc-gen-es,
  protoc-gen-grpc-web,
  protoc-gen-js,
}:

let
  # API v1 stubs (grpc-web) used directly by the console
  protobufGenerated = generateProtobufCode {
    pname = "zitadel-console";
    nativeBuildInputs = [
      grpc-gateway
      protoc-gen-grpc-web
      protoc-gen-js
    ];
    workDir = "console";
    bufArgs = "../proto --include-imports --include-wkt";
    outputPath = "src/app/proto";
    hash = "sha256-kqLaN+toNsxO8Q98OPqXKwXz6be+2+obgLfwfymGMsE=";
  };

  # API v2 stubs (protobuf-es) for the @zitadel/proto workspace package, which
  # @zitadel/client and the console depend on
  protoPackageGenerated = generateProtobufCode {
    pname = "zitadel-proto";
    nativeBuildInputs = [ protoc-gen-es ];
    workDir = "packages/zitadel-proto";
    bufArgs = "../../proto";
    outputPath = ".";
    hash = "sha256-XYpVoMCQgmsMUGS7BBHTLfu5lS85Lau+sow1QW2WtSk=";
  };
in
stdenv.mkDerivation (finalAttrs: {
  pname = "zitadel-console";
  inherit version;

  src = zitadelRepo;

  # @zitadel/proto has no build script and is only generated into; pnpm runs the
  # other two in dependency order
  pnpmWorkspaces = [
    "@zitadel/proto"
    "@zitadel/client"
    "console"
  ];

  pnpmDeps = fetchPnpmDeps {
    inherit (finalAttrs)
      pname
      version
      src
      pnpmWorkspaces
      ;
    pnpm = pnpm_10;
    fetcherVersion = 3;
    hash = "sha256-G/TpFpjCzqUQav0G6lf//cgJjB2C2yeS1/J69AisfU8=";
  };

  nativeBuildInputs = [
    nodejs
    pnpm_10
    pnpmBuildHook
    pnpmConfigHook
  ];

  env.NG_CLI_ANALYTICS = "false";

  preBuild = ''
    cp -r ${protobufGenerated} console/src/app/proto
    cp -r ${protoPackageGenerated}/{cjs,es,types} packages/zitadel-proto/
  '';

  installPhase = ''
    runHook preInstall
    cp -r console/dist/console "$out"
    runHook postInstall
  '';
})
