#!/usr/bin/env bash
# Delivery Timer — генерирует Android-проект и собирает подписанный AAB/APK
set -e
VC="${GITHUB_RUN_NUMBER:-1}"
R=app/src/main
mkdir -p $R/java/de/pozivai/deliverytimer $R/assets $R/res/values $R/res/drawable $R/res/mipmap-anydpi-v26 $R/res/xml
cp index.html $R/assets/index.html
rm -f build*.gradle settings.gradle

cat > settings.gradle <<'EOF'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories { google(); mavenCentral() }
}
rootProject.name = "DeliveryTimer"
include ':app'
EOF

cat > build.gradle <<'EOF'
plugins { id 'com.android.application' version '8.11.1' apply false }
EOF

cat > gradle.properties <<'EOF'
org.gradle.jvmargs=-Xmx2048m -Dfile.encoding=UTF-8
android.useAndroidX=true
android.nonTransitiveRClass=true
EOF

cat > app/build.gradle <<EOF
plugins { id 'com.android.application' }
android {
    namespace 'de.pozivai.deliverytimer'
    compileSdk 36
    defaultConfig {
        applicationId "de.pozivai.deliverytimer"
        minSdk 26
        targetSdk 36
        versionCode $VC
        versionName "1.0.$VC"
    }
    signingConfigs {
        release {
            def ks = System.getenv("KS_PATH")
            if (ks) {
                storeFile file(ks)
                storePassword System.getenv("KS_PASS")
                keyAlias "upload"
                keyPassword System.getenv("KS_PASS")
            }
        }
    }
    buildTypes {
        release {
            minifyEnabled false
            if (System.getenv("KS_PATH")) signingConfig signingConfigs.release
        }
    }
    compileOptions {
        sourceCompatibility JavaVersion.VERSION_17
        targetCompatibility JavaVersion.VERSION_17
    }
    lint { checkReleaseBuilds false; abortOnError false }
}
dependencies {
    implementation 'androidx.core:core:1.13.1'
}
EOF

cat > $R/AndroidManifest.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.VIBRATE" />
    <application
        android:allowBackup="true"
        android:icon="@mipmap/ic_launcher"
        android:roundIcon="@mipmap/ic_launcher"
        android:label="@string/app_name"
        android:theme="@style/AppTheme">
        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:screenOrientation="portrait"
            android:configChanges="orientation|screenSize|keyboardHidden"
            android:launchMode="singleTask">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
        <provider
            android:name="androidx.core.content.FileProvider"
            android:authorities="${applicationId}.files"
            android:exported="false"
            android:grantUriPermissions="true">
            <meta-data
                android:name="android.support.FILE_PROVIDER_PATHS"
                android:resource="@xml/file_paths" />
        </provider>
    </application>
</manifest>
EOF

cat > $R/java/de/pozivai/deliverytimer/MainActivity.java <<'EOF'
package de.pozivai.deliverytimer;

import android.app.Activity;
import android.content.ClipData;
import android.content.Context;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.VibrationEffect;
import android.os.Vibrator;
import android.util.Base64;
import android.view.ViewGroup;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.JavascriptInterface;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.core.content.FileProvider;

import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

public class MainActivity extends Activity {

    private static final int BG = Color.parseColor("#0f1115");
    private static final int REQ_SAVE = 4242;
    private WebView web;
    private byte[] pendingBytes;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON);

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BG);

        web = new WebView(this);
        web.setBackgroundColor(BG);
        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setTextZoom(100);
        web.setWebViewClient(new WebViewClient());
        web.addJavascriptInterface(new Bridge(), "Android");
        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));

        // Android 15+: edge-to-edge — отступы под статус-бар и навигацию
        if (Build.VERSION.SDK_INT >= 30) {
            root.setOnApplyWindowInsetsListener((v, insets) -> {
                android.graphics.Insets i = insets.getInsets(
                        WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                v.setPadding(i.left, i.top, i.right, i.bottom);
                return WindowInsets.CONSUMED;
            });
        }
        setContentView(root);

        // Кнопка "Назад" сворачивает, а не закрывает
        if (Build.VERSION.SDK_INT >= 33) {
            getOnBackInvokedDispatcher().registerOnBackInvokedCallback(
                    android.window.OnBackInvokedDispatcher.PRIORITY_DEFAULT,
                    () -> moveTaskToBack(true));
        }

        web.loadUrl("file:///android_asset/index.html");
    }

    @SuppressWarnings("deprecation")
    @Override
    public void onBackPressed() {
        moveTaskToBack(true);
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (web != null) web.onResume();
    }

    @Override
    protected void onPause() {
        if (web != null) web.onPause();
        super.onPause();
    }

    private void js(String code) {
        runOnUiThread(() -> { if (web != null) web.evaluateJavascript(code, null); });
    }

    // Результат системного диалога "Сохранить как" (Загрузки, Google Диск, любая папка)
    @SuppressWarnings("deprecation")
    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != REQ_SAVE) return;
        if (resultCode == RESULT_OK && data != null && data.getData() != null && pendingBytes != null) {
            try (OutputStream os = getContentResolver().openOutputStream(data.getData())) {
                os.write(pendingBytes);
                js("toastKey('saved')");
            } catch (Exception e) {
                js("toastKey('failed')");
            }
        }
        pendingBytes = null;
    }

    class Bridge {
        @JavascriptInterface
        @SuppressWarnings("deprecation")
        public void vibrate(int ms) {
            Vibrator v = (Vibrator) getSystemService(Context.VIBRATOR_SERVICE);
            if (v == null) return;
            if (Build.VERSION.SDK_INT >= 26) {
                v.vibrate(VibrationEffect.createOneShot(ms, VibrationEffect.DEFAULT_AMPLITUDE));
            } else {
                v.vibrate(ms);
            }
        }

        @JavascriptInterface
        @SuppressWarnings("deprecation")
        public void saveFile(String b64, String name, String mime) {
            pendingBytes = Base64.decode(b64, Base64.DEFAULT);
            runOnUiThread(() -> {
                Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                i.addCategory(Intent.CATEGORY_OPENABLE);
                i.setType(mime);
                i.putExtra(Intent.EXTRA_TITLE, name);
                try {
                    startActivityForResult(i, REQ_SAVE);
                } catch (Exception e) {
                    js("toastKey('failed')");
                }
            });
        }

        // Отправить файл: Google Диск, Telegram, почта и т.д.
        @JavascriptInterface
        public void shareFile(String b64, String name, String mime) {
            try {
                File dir = new File(getCacheDir(), "exports");
                dir.mkdirs();
                File f = new File(dir, name);
                try (FileOutputStream fos = new FileOutputStream(f)) {
                    fos.write(Base64.decode(b64, Base64.DEFAULT));
                }
                Uri uri = FileProvider.getUriForFile(MainActivity.this, getPackageName() + ".files", f);
                Intent s = new Intent(Intent.ACTION_SEND);
                s.setType(mime);
                s.putExtra(Intent.EXTRA_STREAM, uri);
                s.setClipData(ClipData.newRawUri(name, uri));
                s.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION);
                runOnUiThread(() -> startActivity(Intent.createChooser(s, name)));
            } catch (Exception e) {
                js("toastKey('failed')");
            }
        }
    }
}
EOF

cat > $R/res/xml/file_paths.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="exports" path="exports/" />
</paths>
EOF

cat > $R/res/values/strings.xml <<'EOF'
<resources>
    <string name="app_name">Delivery Timer</string>
</resources>
EOF

cat > $R/res/values/styles.xml <<'EOF'
<resources>
    <style name="AppTheme" parent="android:Theme.Material.NoActionBar">
        <item name="android:windowBackground">@color/bg</item>
    </style>
    <color name="bg">#0f1115</color>
    <color name="accent">#3ddc84</color>
</resources>
EOF

cat > $R/res/drawable/ic_fg.xml <<'EOF'
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp" android:height="108dp"
    android:viewportWidth="108" android:viewportHeight="108">
    <path android:fillColor="#0f1115" android:pathData="M48,26h12v6h-12z"/>
    <path android:fillColor="#0f1115" android:pathData="M54,34a22,22 0,1 1,0 44a22,22 0,1 1,0 -44z"/>
    <path android:fillColor="#3ddc84" android:pathData="M54,39a17,17 0,1 1,0 34a17,17 0,1 1,0 -34z"/>
    <path android:strokeColor="#0f1115" android:strokeWidth="4.5"
        android:strokeLineCap="round" android:strokeLineJoin="round"
        android:pathData="M45,56l6,6l12,-13"/>
</vector>
EOF

cat > $R/res/mipmap-anydpi-v26/ic_launcher.xml <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@color/accent"/>
    <foreground android:drawable="@drawable/ic_fg"/>
</adaptive-icon>
EOF

# Ключ подписи из секретов GitHub
if [ -n "$KEYSTORE_BASE64" ]; then
  echo "$KEYSTORE_BASE64" | base64 -d > "$PWD/upload.jks"
  export KS_PATH="$PWD/upload.jks"
  export KS_PASS="$KEYSTORE_PASSWORD"
  gradle --no-daemon bundleRelease assembleRelease
else
  echo "!!! Нет секрета KEYSTORE_BASE64 — собираю только тестовый APK"
  gradle --no-daemon assembleDebug
fi

mkdir -p out
cp app/build/outputs/bundle/release/*.aab out/DeliveryTimer-$VC.aab 2>/dev/null || true
cp app/build/outputs/apk/release/*.apk out/DeliveryTimer-$VC.apk 2>/dev/null || true
cp app/build/outputs/apk/debug/*.apk out/DeliveryTimer-$VC-debug.apk 2>/dev/null || true
ls -la out
