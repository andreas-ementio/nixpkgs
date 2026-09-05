{
  stdenv,
  buildGoModule,
  callPackage,
  emptyDirectory,
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
  yq-go,
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

  # `buf export` writes out exactly the content of the pinned BSR commit, so
  # this hash tracks upstream's proto/buf.lock and nothing else. Fetching the
  # dependencies here rather than letting buf reach the network during codegen
  # is what keeps the generated output out of a fixed-output derivation - see
  # generateProtobufCode below.
  fetchProtobufDep =
    {
      remote,
      owner,
      repository,
      commit,
      hash,
    }:
    stdenv.mkDerivation {
      pname = "${repository}-buf-dep";
      version = commit;

      src = emptyDirectory;

      nativeBuildInputs = [
        buf
        cacert
        writableTmpDirAsHomeHook
      ];

      buildPhase = ''
        runHook preBuild
        buf export --output=$out ${lib.escapeShellArg "${remote}/${owner}/${repository}:${commit}"}
        runHook postBuild
      '';

      dontInstall = true;

      outputHashMode = "recursive";
      outputHashAlgo = "sha256";
      outputHash = hash;
    };

  # Mirrors proto/buf.lock; the attribute name is the directory the export is
  # mounted at inside the source tree.
  protobufDeps = {
    protoc-gen-validate = {
      remote = "buf.build";
      owner = "envoyproxy";
      repository = "protoc-gen-validate";
      commit = "6607b10f00ed4a3d98f906807131c44a";
      hash = "sha256-xil1euaa8TI7rlCdb5tnFVfKgorRMbtmvJSsE2hsmAs=";
    };
    googleapis = {
      remote = "buf.build";
      owner = "googleapis";
      repository = "googleapis";
      commit = "75b4300737fb4efca0831636be94e517";
      hash = "sha256-Kb5BLmfInJe1Q5rollD0B8gPOVkeFtIeDhQ/WGpIKmY=";
    };
    grpc-gateway = {
      remote = "buf.build";
      owner = "grpc-ecosystem";
      repository = "grpc-gateway";
      commit = "a1ecdc58eccd49aa8bea2a7a9022dc27";
      hash = "sha256-Kpu8XdLTU5Z6omb58Ogik/RjDHLH8e6SqPuwiRYY9nE=";
    };
  };

  # buf normally resolves proto/buf.yaml's `deps` over the network, which would
  # force the generated code into a fixed-output derivation whose hash depends
  # on the versions of buf and of every protoc plugin below. Instead the deps
  # are prefetched above and registered as plain workspace directories, so this
  # is an ordinary sandboxed build that just rebuilds when a plugin changes.
  generateProtobufCode =
    {
      pname,
      nativeBuildInputs ? [ ],
      bufArgs ? "",
      workDir ? ".",
      outputPath,
    }:
    stdenv.mkDerivation {
      pname = "${pname}-buf-generated";
      inherit version;

      src = zitadelRepo;

      nativeBuildInputs = nativeBuildInputs ++ [
        buf
        writableTmpDirAsHomeHook
        yq-go
      ];

      buildPhase = ''
        runHook preBuild

        yq --inplace '.deps = []' proto/buf.yaml
        yq --inplace '.deps = []' proto/buf.lock
        ${lib.concatLines (
          lib.mapAttrsToList (name: dep: ''
            ln -s ${fetchProtobufDep dep} ${name}
            yq --inplace '.directories += [ "${name}" ]' buf.work.yaml
          '') protobufDeps
        )}
        cd ${workDir}
        buf generate ${bufArgs}

        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        cp -r ${outputPath} $out
        runHook postInstall
      '';
    };

  protobufGenerated = generateProtobufCode {
    pname = "zitadel";
    # the workspace now also holds the prefetched deps, so scope generation
    # to zitadel's own module
    bufArgs = "proto";
    nativeBuildInputs = [
      grpc-gateway
      protocPlugins
      protoc-gen-connect-go
      protoc-gen-go
      protoc-gen-go-grpc
      protoc-gen-validate
    ];
    outputPath = ".artifacts";
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
    inherit fetchProtobufDep;
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
