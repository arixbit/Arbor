cask "arbor" do
  version "1.0.25"
  sha256 "2e14c293960e7ce25a6791f246007715d8e3a577456d7458cb46b54f8d3fe1e7"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
