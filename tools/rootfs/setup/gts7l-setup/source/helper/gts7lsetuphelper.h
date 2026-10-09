// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once

#include <KAuth/ActionReply>
#include <QObject>

class Gts7lSetupHelper : public QObject
{
    Q_OBJECT

public Q_SLOTS:
    KAuth::ActionReply apply(const QVariantMap &args);
};
