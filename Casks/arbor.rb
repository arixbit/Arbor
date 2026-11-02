cask "arbor" do
  version "1.0.34"
  sha256 "76698f320a915c8b52a9ad3aef11a42f5f398f22cacddb3f85ece297de550b8e"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
