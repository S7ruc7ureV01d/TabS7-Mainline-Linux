// SPDX-License-Identifier: LGPL-2.1-or-later
#include "gts7lsetup.h"

#include <KAuth/Action>
#include <KAuth/ExecuteJob>
#include <QDebug>

bool Gts7lSetup::apply(const QString &username)
{
    KAuth::Action action(QStringLiteral("org.gts7l.setup.apply"));
    action.setHelperId(QStringLiteral("org.gts7l.setup"));
    action.setArguments({
        {QStringLiteral("username"), username},
        {QStringLiteral("autoBrightness"), m_autoBrightness},
        {QStringLiteral("autoRotate"), m_autoRotate},
        {QStringLiteral("autologin"), m_autologin},
        {QStringLiteral("ssh"), m_ssh},
        {QStringLiteral("windowsSupport"), m_windowsSupport},
        {QStringLiteral("rootPassword"), m_rootPasswordEnabled ? m_rootPassword : QString()},
    });

    KAuth::ExecuteJob *job = action.execute();
    if (!job->exec()) {
        qWarning() << "gts7l-setup: apply failed:" << job->errorString();
        return false;
    }
    m_rootPassword.clear();
    return true;
}
