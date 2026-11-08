"""Compile the actual Gradle pure functions, without Android/Gradle/native builds.

Optional compiler inputs: kotlinc on PATH, or RC_KOTLIN_COMPILER_CLASSPATH plus
RC_KOTLIN_STDLIB_JAR for an existing offline embeddable Kotlin compiler. No downloads.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
COMPILER_CP = os.environ.get("RC_KOTLIN_COMPILER_CLASSPATH", "")
STDLIB = os.environ.get("RC_KOTLIN_STDLIB_JAR", "")
KOTLINC = shutil.which("kotlinc")

KOTLIN_MATRIX = r'''
fun main() {
    var count = 0
    fun passes(name: String, block: () -> Unit) {
        try { block(); count++ } catch (error: Throwable) {
            throw AssertionError("Scenario failed: $name", error)
        }
    }
    fun rejected(block: () -> Unit) {
        var failed = false
        try { block() } catch (_: IllegalArgumentException) { failed = true }
        check(failed) { "Expected rejection" }
    }
    fun encode(vararg entries: String): String = entries.joinToString(",") {
        Base64.getEncoder().encodeToString(it.toByteArray(Charsets.UTF_8))
    }
    val flag = "RC_OAUTH_REUSE_REFERENCE_CLIENT"
    val uri = "RC_OAUTH_REDIRECT_URI"
    val client = "RC_OAUTH_CLIENT_ID"
    val reference = mapOf(flag to "true", uri to "reai-mobile://callback",
                          client to "58Ff3x3aEtw2DZHo19CP6Hpw5fpfL1vo")
    passes("no defines uses safe defaults") {
        check(rcOAuthCallbackScheme(decodeRcDartDefines("")) == "recording-card")
    }
    passes("normal explicit false") {
        check(rcOAuthCallbackScheme(decodeRcDartDefines(encode(
            "$flag=false", "$uri=recording-card://callback", "RC_TEXT_MODEL="))) == "recording-card")
    }
    passes("explicit reference tuple from Flutter encoding") {
        check(rcOAuthCallbackScheme(decodeRcDartDefines(encode(
            "$flag=true", "$uri=reai-mobile://callback", "$client=${reference[client]}"))) == "reai-mobile")
    }
    passes("value may contain equals and UTF8") {
        check(decodeRcDartDefines(encode("RC_OAUTH_SCOPE=a=b 中文"))["RC_OAUTH_SCOPE"] == "a=b 中文")
    }
    passes("reference without opt in") { rejected { rcOAuthCallbackScheme(mapOf(uri to "reai-mobile://callback")) } }
    passes("reference with false") { rejected { rcOAuthCallbackScheme(reference + (flag to "false")) } }
    passes("reuse true default redirect fails closed") { rejected { rcOAuthCallbackScheme(mapOf(flag to "true")) } }
    passes("reuse true own redirect") { rejected { rcOAuthCallbackScheme(reference + (uri to "recording-card://callback")) } }
    passes("reuse wrong client") { rejected { rcOAuthCallbackScheme(reference + (client to "other-public-client")) } }
    passes("empty client") { rejected { rcOAuthCallbackScheme(mapOf(client to "")) } }
    passes("whitespace client") { rejected { rcOAuthCallbackScheme(mapOf(client to "public client")) } }
    passes("dedicated client only own scheme") {
        check(rcOAuthCallbackScheme(mapOf(client to "dedicated-public-client")) == "recording-card")
    }
    for (bad in listOf("true ", "TRUE", "False", "yes", "1", "0", "")) {
        passes("strict opt-in $bad") { rejected { rcOAuthCallbackScheme(reference + (flag to bad)) } }
    }
    for (other in listOf("RC_ASR_ALLOW_DOWNLOAD", "RC_ASR_LICENSE_ACCEPTED",
                         "RC_UPLOAD_RAW_CONTRACT_APPROVED", "RC_UPLOAD_OAUTH_BEARER_APPROVED")) {
        passes("known flag strict $other") { rejected { rcOAuthCallbackScheme(mapOf(other to "TRUE")) } }
    }
    for (bad in listOf("reai-mobile://callback/", "reai-mobile://callback?x=1", "reai-mobile://callback#x",
                       "reai-mobile://other", "REAI-MOBILE://callback")) {
        passes("exact reference redirect $bad") { rejected { rcOAuthCallbackScheme(reference + (uri to bad)) } }
    }
    passes("bad base64") { rejected { decodeRcDartDefines("%%%"); Unit } }
    passes("empty encoding entry") { rejected { decodeRcDartDefines(encode("a=b") + ","); Unit } }
    passes("no separator") { rejected { decodeRcDartDefines(encode("not-a-pair")); Unit } }
    passes("empty key") { rejected { decodeRcDartDefines(encode("=value")); Unit } }
    passes("duplicate define") { rejected { decodeRcDartDefines(encode("$flag=false", "$flag=true")); Unit } }
    passes("malformed UTF8") { rejected { decodeRcDartDefines(Base64.getEncoder().encodeToString(byteArrayOf(0xff.toByte()))); Unit } }
    println("Android OAuth Kotlin matrix: $count cases PASS (pure functions, no Android build).")
}
'''


@unittest.skipUnless(KOTLINC or (COMPILER_CP and STDLIB), "Optional offline Kotlin compiler not configured")
class AndroidOAuthKotlinTests(unittest.TestCase):
    def test_actual_gradle_functions_compile_and_pass_matrix(self):
        gradle = (ROOT / "app/android/app/build.gradle.kts").read_text()
        functions = gradle.split("// BEGIN RC_OAUTH_CONFIG: pure functions also exercised by scripts/tests.\n", 1)[1].split("// END RC_OAUTH_CONFIG", 1)[0]
        imports = "\n".join(line for line in gradle.splitlines() if line.startswith("import "))
        with tempfile.TemporaryDirectory(prefix="recording-card-kotlin-") as directory:
            root = Path(directory)
            source = root / "NativeOAuthTest.kt"
            source.write_text(imports + "\n" + functions + "\n" + KOTLIN_MATRIX)
            if COMPILER_CP and STDLIB:
                classes = root / "classes"
                command = ["java", "-cp", COMPILER_CP, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                           "-no-stdlib", "-no-reflect", "-classpath", STDLIB, "-d", str(classes), str(source)]
                runtime = ["java", "-cp", str(classes) + os.pathsep + STDLIB, "NativeOAuthTestKt"]
            else:
                jar = root / "native-tests.jar"
                command = [KOTLINC, str(source), "-include-runtime", "-d", str(jar)]
                runtime = ["java", "-jar", str(jar)]
            compile_result = subprocess.run(command, capture_output=True, text=True, timeout=90)
            self.assertEqual(compile_result.returncode, 0, compile_result.stdout + compile_result.stderr)
            result = subprocess.run(runtime, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("cases PASS", result.stdout)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
