// SPDX-License-Identifier: LGPL-2.1-or-later
// Choices made on the gts7l page of the first-boot wizard, applied as root
// through the org.gts7l.setup KAuth helper when the wizard finishes.
#pragma once

#include <QObject>
#include <qqmlintegration.h>

class Gts7lSetup : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

    Q_PROPERTY(bool autoBrightness MEMBER m_autoBrightness NOTIFY changed)
    Q_PROPERTY(bool autoRotate MEMBER m_autoRotate NOTIFY changed)
    Q_PROPERTY(bool autologin MEMBER m_autologin NOTIFY changed)
    Q_PROPERTY(bool ssh MEMBER m_ssh NOTIFY changed)
    Q_PROPERTY(bool windowsSupport MEMBER m_windowsSupport NOTIFY changed)
    Q_PROPERTY(bool rootPasswordEnabled MEMBER m_rootPasswordEnabled NOTIFY changed)
    Q_PROPERTY(QString rootPassword MEMBER m_rootPassword NOTIFY changed)

public:
    using QObject::QObject;

    /// Apply everything; username is the account the wizard is creating.
    Q_INVOKABLE bool apply(const QString &username);

Q_SIGNALS:
    void changed();

private:
    bool m_autoBrightness = true;
    bool m_autoRotate = true;
    bool m_autologin = false;
    bool m_ssh = false;
    bool m_windowsSupport = false;
    bool m_rootPasswordEnabled = false;
    QString m_rootPassword;
};
