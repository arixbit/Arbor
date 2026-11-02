cask "arbor" do
  version "1.0.32"
  sha256 "6082a4aea1af434cbeee11d0c5a26e1250b4169a2bfab802ba62e1abd3bb08de"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
