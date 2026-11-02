cask "arbor" do
  version "1.0.31"
  sha256 "1cf90b96de212f4afcf2ce4d17d00001f984dc7b092ea7843c157387ab7f0fb2"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
