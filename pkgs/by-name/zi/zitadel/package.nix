{
  stdenv,
  buildGoModule,
  callPackage,
  fetchFromGitHub,
  lib,

  buf,
  cacert,
  dart-sass,
  grpc-gateway,
  protoc-gen-connect-go,
  protoc-gen-go,
  protoc-gen-go-grpc,
  protoc-gen-validate,
  statik,
  writableTmpDirAsHomeHook,
}:

let
  version = "4.17.3";
  zitadelRepo = fetchFromGitHub {
    owner = "zitadel";
    repo = "zitadel";
    tag = "v${version}";
    hash = "sha256-nA9GgsvCKFNaHjMLwb1SNNZPLL02YP8vK9oec2qVDnE=";
  };
  goModulesHash = "sha256-8/TkV1JTKNSIknzEPbTDWzcOZQ6jCEkc6vSLLhdLYrs=";

  # Both consumers below vendor the same module set, and a fixed-output
  # derivation is keyed on its name, so share one name to fetch it once.
  # This means they must keep producing identical content: everything
  # buildGoModule forwards to the vendor derivation (prePatch, patches,
  # patchFlags, postPatch, preBuild, sourceRoot, setSourceRoot, env) has to
  # stay equal between them, or one will stop matching goModulesHash. Note
  # the main package deliberately uses postConfigure, not preBuild, for its
  # codegen for exactly this reason.
  overrideModAttrs = _: {
    name = "zitadel-${version}-go-modules";
  };

  protocPlugins = buildGoModule {
    pname = "zitadel-protoc-plugins";
    inherit version;

    src = zitadelRepo;

    proxyVendor = true;
    vendorHash = goModulesHash;
    inherit overrideModAttrs;

    subPackages = [
      "internal/protoc/protoc-gen-authoption"
      "internal/protoc/protoc-gen-zitadel"
    ];
  };

  # Buf downloads dependencies from an external repo - there doesn't seem to
  # really be any good way around it. We'll use a fixed-output derivation so it
  # can download what it needs, and output the relevant generated code for use
  # during the main build.
  generateProtobufCode =
    {
      pname,
      nativeBuildInputs ? [ ],
      bufArgs ? "",
      workDir ? ".",
      outputPath,
      hash,
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version;

      src = zitadelRepo;

      nativeBuildInputs = nativeBuildInputs ++ [
        buf
        cacert
        writableTmpDirAsHomeHook
      ];

      buildPhase = ''
        runHook preBuild
        cd ${workDir}
        buf generate ${bufArgs}
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        cp -r ${outputPath} $out
        runHook postInstall
      '';

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hash;
    };

  protobufGenerated = generateProtobufCode {
    pname = "zitadel";
    nativeBuildInputs = [
      grpc-gateway
      protocPlugins
      protoc-gen-connect-go
      protoc-gen-go
      protoc-gen-go-grpc
      protoc-gen-validate
    ];
    outputPath = ".artifacts";
    hash = "sha256-ut0C9QdWtYDj12ODnEXrqNErX+g9g7n1uqnKYog14fY=";
  };
in
buildGoModule (finalAttrs: {
  pname = "zitadel";
  inherit version;

  src = zitadelRepo;

  nativeBuildInputs = [
    dart-sass
    statik
  ];

  proxyVendor = true;
  vendorHash = goModulesHash;
  inherit overrideModAttrs;

  subPackages = [ "." ];

  ldflags = [
    "-s"
    "-w"
    "-X github.com/zitadel/zitadel/cmd/build.version=${version}"
  ];

  # Adapted from the `@zitadel/api` nx targets in apps/api/project.json, with
  # dependency fetching and protobuf codegen bits removed. This is postConfigure
  # rather than preBuild because buildGoModule forwards preBuild to the vendor
  # derivation, which only needs the plain module download - and moving it back
  # to preBuild would make that derivation diverge from the shared one above.
  postConfigure = ''
    mkdir -p pkg/grpc openapi/v2/zitadel
    cp -r ${protobufGenerated}/grpc/github.com/zitadel/zitadel/pkg/grpc/* pkg/grpc
    cp -r ${protobufGenerated}/grpc/zitadel/ openapi/v2/zitadel

    # upstream runs this through `go generate` -> `pnpm sass`
    (cd internal/api/ui/login/static/resources && sass themes/scss/zitadel.scss themes/zitadel/css/zitadel.css)
    go generate internal/api/ui/login/statik/generate.go
    go generate internal/notification/statik/generate.go
    go generate internal/statik/generate.go

    # only -directory matters; the -assets markdown is a docs artifact we discard
    go run internal/api/assets/generator/asset_generator.go -directory=internal/api/assets/generator/ -assets=$TMPDIR/assets.mdx

    cp -r ${finalAttrs.passthru.console}/* internal/api/ui/console/static
  '';

  doCheck = false;

  passthru = {
    console = callPackage (import ./console.nix {
      inherit generateProtobufCode version zitadelRepo;
    }) { };
  };

  meta = {
    description = "Identity and access management platform";
    homepage = "https://zitadel.com/";
    downloadPage = "https://github.com/zitadel/zitadel/releases";
    changelog = "https://github.com/zitadel/zitadel/releases/tag/v${version}";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
    license = lib.licenses.asl20;
    sourceProvenance = [ lib.sourceTypes.fromSource ];
    maintainers = [ lib.maintainers.nrabulinski ];
    mainProgram = "zitadel";
  };
})
