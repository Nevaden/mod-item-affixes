// Reforge NPC (docs/REFORGE_PLAN.md, Stage 3). Blurb + one gossip option
// ("Reforge") that tells the client-side addon to open the reforge frame
// (ReforgeUI.lua, Stage 4).

#include "CreatureScript.h"
#include "ItemAffix.h"
#include "Player.h"
#include "ScriptedGossip.h"

enum ReforgeMasterGossip
{
    GOSSIP_ACTION_REFORGE = GOSSIP_ACTION_INFO_DEF + 1,
};

class npc_reforge_master : public CreatureScript
{
public:
    npc_reforge_master() : CreatureScript("npc_reforge_master") {}

    bool OnGossipHello(Player* player, Creature* creature) override
    {
        AddGossipItemFor(player, GOSSIP_ICON_CHAT, "Reforge", GOSSIP_SENDER_MAIN, GOSSIP_ACTION_REFORGE);
        SendGossipMenuFor(player, player->GetGossipTextId(creature), creature->GetGUID());
        return true;
    }

    bool OnGossipSelect(Player* player, Creature* /*creature*/, uint32 /*sender*/, uint32 action) override
    {
        if (action == GOSSIP_ACTION_REFORGE)
        {
            CloseGossipMenuFor(player);
            sItemAffixMgr->SendAddonMsg(player, "REFORGE_OPEN");
        }
        return true;
    }
};

void AddSC_npc_reforge_master()
{
    new npc_reforge_master();
}
