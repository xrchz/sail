(*Generated by Lem from prompt.lem.*)
open HolKernel Parse boolLib bossLib;
open prompt_monadTheory state_monadTheory stateTheory;

val _ = numLib.prefer_num();



val _ = new_theory "prompt"

(*open import Prompt_monad*)
(*open import State_monad*)
(*open import State*)
val _ = export_theory()

