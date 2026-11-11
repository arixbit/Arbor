cask "arbor" do
  version "1.0.38"
  sha256 "9e63d9c7a6479f15bdabb879ff04da71e4c5e8035f3277769158f28c6b25fc3a"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
