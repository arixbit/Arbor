cask "arbor" do
  version "1.0.34"
  sha256 "1fd08493e426bb34a96739ff52c7e58b31461c334007cad56912422e7e4effdb"

  url "https://github.com/arixbit/Arbor/releases/download/v#{version}/Arbor-#{version}-unsigned-arm64.dmg"
  name "Arbor"
  desc "Native Git workbench"
  homepage "https://github.com/arixbit/Arbor"

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Arbor.app"
end
