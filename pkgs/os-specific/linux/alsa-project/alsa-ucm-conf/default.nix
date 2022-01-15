{ lib, stdenv, fetchFromGitHub }:

stdenv.mkDerivation rec {
  pname = "alsa-ucm-conf";
  version = "1.2.6.3";

  src = fetchFromGitHub {
    owner = "tomfitzhenry";
    repo = pname;
    rev = "00da81e546718f05a823fe7ab177bf80fff30039";
    sha256 = "sha256-VXNzir+bqZZViaBRsXOdm6pEf8zaWXodFlY+0Rc/XgE=";
  };

  dontBuild = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/alsa
    cp -r ucm ucm2 $out/share/alsa

    runHook postInstall
  '';

  meta = with lib; {
    homepage = "https://www.alsa-project.org/";
    description = "ALSA Use Case Manager configuration";

    longDescription = ''
      The Advanced Linux Sound Architecture (ALSA) provides audio and
      MIDI functionality to the Linux-based operating system.
    '';

    license = licenses.bsd3;
    maintainers = [ maintainers.roastiek ];
    platforms = platforms.linux;
  };
}
