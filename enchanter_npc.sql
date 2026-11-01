DELETE FROM `creature_template` WHERE `entry` = 601015;

INSERT INTO `creature_template`
    (`entry`, `name`, `subname`, `minlevel`, `maxlevel`, `exp`, `faction`,
     `npcflag`, `unit_flags`, `type`, `flags_extra`, `VerifiedBuild`)
VALUES
    (601015, 'Beauregard Boneglitter', 'Master Enchanter',
     80, 80, 2, 35, 1, 768, 7, 2, 12340);

DELETE FROM `creature_template_model` WHERE `CreatureID` = 601015;

INSERT INTO `creature_template_model`
    (`CreatureID`, `Idx`, `CreatureDisplayID`, `DisplayScale`, `Probability`, `VerifiedBuild`)
VALUES
    (601015, 0, 25907, 1, 1, 12340);
