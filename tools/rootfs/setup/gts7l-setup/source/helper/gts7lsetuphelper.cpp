// SPDX-License-Identifier: LGPL-2.1-or-later
//
// Root side of the gts7l first-boot page. Runs once, when plasma-setup's
// wizard finishes, before it copies the setup session's display config to
// the new user and logs out.

#include "gts7lsetuphelper.h"

#include <KAuth/HelperSupport>

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QProcess>
#include <QRegularExpression>
#include <QSaveFile>

using namespace KAuth;

namespace
{
// The setup session's KWin output config; plasma-setup copies it to the new
// user right after the distro hooks run (setnewuserdisplayscaling).
const QString SETUP_KWIN_CONFIG = QStringLiteral("/run/plasma-setup/.config/kwinoutputconfig.json");
// The setup session's kwinrc, also copied to the new user
const QString SETUP_KWINRC = QStringLiteral("/run/plasma-setup/.config/kwinrc");
const QString AUTOLOGIN_CONF = QStringLiteral("/etc/plasmalogin.conf.d/50-gts7l-autologin.conf");
const QString CHOICES = QStringLiteral("/etc/gts7l/setup-choices");
const QString PANEL = QStringLiteral("DSI-1");

// Auto-brightness curve (lux for 0, 10, ..., 100 % brightness), the same
// starting curve as tools/rootfs/sensors/autobrightness/.
const QList<int> BRIGHTNESS_CURVE = {0, 1, 3, 8, 20, 45, 90, 180, 350, 700, 1400};

ActionReply error(const QString &message)
{
    ActionReply reply = ActionReply::HelperErrorReply();
    reply.setErrorDescription(message);
    return reply;
}

// Runs a program; stdin is optional. Returns an empty string on success.
QString run(const QString &program, const QStringList &args, const QByteArray &input = {})
{
    QProcess p;
    p.start(program, args);
    if (!p.waitForStarted(5000)) {
        return program + QStringLiteral(": failed to start");
    }
    if (!input.isEmpty()) {
        p.write(input);
    }
    p.closeWriteChannel();
    if (!p.waitForFinished(30000) || p.exitStatus() != QProcess::NormalExit || p.exitCode() != 0) {
        return program + QStringLiteral(" ") + args.join(QLatin1Char(' ')) + QStringLiteral(": ")
            + QString::fromLocal8Bit(p.readAllStandardError()).trimmed();
    }
    return {};
}

bool writeFile(const QString &path, const QByteArray &data)
{
    QDir().mkpath(QFileInfo(path).absolutePath());
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly)) {
        return false;
    }
    f.write(data);
    return f.commit();
}

// The wizard runs with the stock keyboard (gts7l-plasma-setup tmpfiles: the
// floating one is a normal window, hidden behind the fullscreen wizard). Drop
// that choice from the kwinrc the new user gets, so the system default
// (/etc/xdg/kwinrc: the floating keyboard) applies.
void dropSetupInputMethod()
{
    QFile f(SETUP_KWINRC);
    if (!f.open(QIODevice::ReadOnly)) {
        return;
    }
    QByteArray out;
    const QList<QByteArray> lines = f.readAll().split('\n');
    f.close();
    for (int i = 0; i < lines.size(); ++i) {
        if (lines[i].startsWith("InputMethod=")) {
            continue;
        }
        out += lines[i];
        if (i + 1 < lines.size()) {
            out += '\n';
        }
    }
    if (f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        f.write(out);
        f.close();
    }
}

// Built-in panel defaults for the new user: portrait (the panel's native
// orientation), 120 Hz, auto-rotation and auto-brightness as chosen.
QString adjustDisplayConfig(bool autoBrightness, bool autoRotate)
{
    QFile f(SETUP_KWIN_CONFIG);
    if (!f.open(QIODevice::ReadOnly)) {
        return QStringLiteral("no setup display config at ") + SETUP_KWIN_CONFIG;
    }
    QJsonDocument doc = QJsonDocument::fromJson(f.readAll());
    f.close();
    if (!doc.isArray()) {
        return QStringLiteral("unexpected format in ") + SETUP_KWIN_CONFIG;
    }

    QJsonArray sections = doc.array();
    bool found = false;
    for (int s = 0; s < sections.size(); ++s) {
        QJsonObject section = sections[s].toObject();
        if (section[QStringLiteral("name")].toString() != QLatin1String("outputs")) {
            continue;
        }
        QJsonArray outputs = section[QStringLiteral("data")].toArray();
        for (int i = 0; i < outputs.size(); ++i) {
            QJsonObject o = outputs[i].toObject();
            if (o[QStringLiteral("connectorName")].toString() != PANEL) {
                continue;
            }
            found = true;
            o[QStringLiteral("transform")] = QStringLiteral("Normal");
            o[QStringLiteral("autoRotation")] = autoRotate ? QStringLiteral("Always") : QStringLiteral("Never");
            o[QStringLiteral("automaticBrightness")] = autoBrightness;
            QJsonArray curve;
            for (int lux : BRIGHTNESS_CURVE) {
                curve.append(lux);
            }
            o[QStringLiteral("autoBrightnessCurve")] = curve;
            QJsonObject mode = o[QStringLiteral("mode")].toObject();
            mode[QStringLiteral("width")] = 1600;
            mode[QStringLiteral("height")] = 2560;
            mode[QStringLiteral("refreshRate")] = 120000;
            o[QStringLiteral("mode")] = mode;
            outputs[i] = o;
        }
        section[QStringLiteral("data")] = outputs;
        sections[s] = section;
    }
    if (!found) {
        return QStringLiteral("no ") + PANEL + QStringLiteral(" entry in ") + SETUP_KWIN_CONFIG;
    }

    // Keep the setup user's ownership: write in place.
    if (!f.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        return QStringLiteral("cannot write ") + SETUP_KWIN_CONFIG;
    }
    f.write(QJsonDocument(sections).toJson());
    f.close();
    return {};
}
}

ActionReply Gts7lSetupHelper::apply(const QVariantMap &args)
{
    const QString username = args.value(QStringLiteral("username")).toString();
    const bool autoBrightness = args.value(QStringLiteral("autoBrightness"), true).toBool();
    const bool autoRotate = args.value(QStringLiteral("autoRotate"), true).toBool();
    const bool autologin = args.value(QStringLiteral("autologin")).toBool();
    const bool ssh = args.value(QStringLiteral("ssh")).toBool();
    const bool windowsSupport = args.value(QStringLiteral("windowsSupport")).toBool();
    const QString rootPassword = args.value(QStringLiteral("rootPassword")).toString();

    static const QRegularExpression validUser(QStringLiteral("^[a-z_][a-z0-9_-]{0,31}$"));
    if (autologin && !validUser.match(username).hasMatch()) {
        return error(QStringLiteral("invalid username for autologin: ") + username);
    }
    if (rootPassword.contains(QLatin1Char('\n')) || rootPassword.contains(QLatin1Char(':'))) {
        return error(QStringLiteral("the root password must not contain ':' or a newline"));
    }

    QStringList problems;

    // Root: a password, or locked (the admin user has sudo through wheel).
    const QString rootResult = rootPassword.isEmpty()
        ? run(QStringLiteral("passwd"), {QStringLiteral("--lock"), QStringLiteral("root")})
        : run(QStringLiteral("chpasswd"), {}, QStringLiteral("root:%1\n").arg(rootPassword).toUtf8());
    if (!rootResult.isEmpty()) {
        problems << rootResult;
    }

    // Automatic login into Plasma for the new user (Plasma Login Manager).
    if (autologin) {
        const QByteArray conf = QStringLiteral("# gts7l first-boot setup: log in automatically\n[Autologin]\nUser=%1\nSession=plasma\n").arg(username).toUtf8();
        if (!writeFile(AUTOLOGIN_CONF, conf)) {
            problems << QStringLiteral("cannot write ") + AUTOLOGIN_CONF;
        }
    } else {
        QFile::remove(AUTOLOGIN_CONF);
    }

    const QString sshResult = run(QStringLiteral("systemctl"), {ssh ? QStringLiteral("enable") : QStringLiteral("disable"), QStringLiteral("sshd.service")});
    if (!sshResult.isEmpty()) {
        problems << sshResult;
    }

    // Windows programs: Wine (Hangover) is downloaded once the tablet is
    // online. Enabled so it retries on later boots until it succeeds, and
    // started now without waiting (it runs after the wizard, in the
    // background, and notifies the user).
    QString wineResult = run(QStringLiteral("systemctl"),
                             {windowsSupport ? QStringLiteral("enable") : QStringLiteral("disable"),
                              QStringLiteral("gts7l-install-windows-support.service")});
    if (wineResult.isEmpty() && windowsSupport) {
        wineResult = run(QStringLiteral("systemctl"),
                         {QStringLiteral("start"), QStringLiteral("--no-block"),
                          QStringLiteral("gts7l-install-windows-support.service")});
    }
    if (!wineResult.isEmpty()) {
        problems << wineResult;
    }

    dropSetupInputMethod();

    const QString displayResult = adjustDisplayConfig(autoBrightness, autoRotate);
    if (!displayResult.isEmpty()) {
        problems << displayResult;
    }

    // A record of the choices (no secrets), for support and later tools.
    writeFile(CHOICES,
              QStringLiteral("AUTOBRIGHTNESS=%1\nAUTOROTATE=%2\nAUTOLOGIN=%3\nSSH=%4\nWINDOWS_SUPPORT=%5\nROOT_PASSWORD=%6\n")
                  .arg(autoBrightness)
                  .arg(autoRotate)
                  .arg(autologin)
                  .arg(ssh)
                  .arg(windowsSupport)
                  .arg(rootPassword.isEmpty() ? QStringLiteral("locked") : QStringLiteral("set"))
                  .toUtf8());

    if (!problems.isEmpty()) {
        return error(problems.join(QStringLiteral("; ")));
    }
    return ActionReply::SuccessReply();
}

KAUTH_HELPER_MAIN("org.gts7l.setup", Gts7lSetupHelper)

#include "moc_gts7lsetuphelper.cpp"
