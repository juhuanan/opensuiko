//! Pure physical damage, accuracy, critical and priority rules.
const systems = @import("battle_rules");

pub fn physicalDamage(attack: u16, defense: u16, roll: u15, defending: bool) u32 {
    return systems.physicalDamage(attack, defense, roll, defending);
}
pub fn hits(skill: u16, target_skill: u16, roll: u15) bool {
    return systems.accuracyThreshold(skill, target_skill, false) > roll % 100;
}
pub fn hitsWithAccuracyPenalty(skill: u16, target_skill: u16, roll: u15, halved: bool) bool {
    return systems.accuracyThreshold(skill, target_skill, halved) > roll % 100;
}
pub fn critical(skill: u16, luck: u16, killer: bool, roll: u15) bool {
    return systems.criticalHit(skill, luck, killer, roll);
}
pub fn priority(speed: u16, roll: u15) i32 {
    return @as(i32, speed) * 10 - 5 + @as(i32, roll % 10);
}
