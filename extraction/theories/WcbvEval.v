(* Distributed under the terms of the MIT license.   *)

From Coq Require Import Bool String List Program BinPos Compare_dec Omega.
From Template Require Import config utils Ast univ.
From TemplateExtraction Require Import Ast Induction LiftSubst UnivSubst Typing.
From Template Require AstUtils.
Require Import String.
Local Open Scope string_scope.
Set Asymmetric Patterns.

Existing Instance config.default_checker_flags.


(** * Weak (head) call-by-value evaluation strategy.

  The [wcbveval] inductive relation specifies weak cbv evaluation.  It
  is shown to be a subrelation of the 1-step reduction relation from
  which conversion is defined. Hence two terms that reduce to the same
  wcbv head normal form are convertible.

  This reduction strategy is supposed to mimick at the Coq level the
  reduction strategy of ML programming languages. It is used to state
  the extraction conjecture that can be applied to Coq terms to produce
  (untyped) terms where all proofs are erased to a dummy value. *)

(** Helpers for reduction *)

Definition iota_red npar c args brs :=
  (mkApps (snd (List.nth c brs (0, tBox))) (List.skipn npar args)).

Definition fix_subst (l : mfixpoint term) :=
  let fix aux n :=
      match n with
      | 0 => []
      | S n => tFix l n :: aux n
      end
  in aux (List.length l).

Definition unfold_fix (mfix : mfixpoint term) (idx : nat) :=
  match List.nth_error mfix idx with
  | Some d => Some (d.(rarg), substl (fix_subst mfix) d.(dbody))
  | None => None
  end.

Definition is_constructor n ts :=
  match List.nth_error ts n with
  | Some a =>
    match a with
    | tConstruct _ _ _ => true
    | tApp (tConstruct _ _ _) _ => true
    | _ => false
    end
  | None => false
  end.


Definition mktApp f l :=
  match l with
  | nil => f
  | l => tApp f l
  end.

(** ** Big step version of weak cbv beta-zeta-iota-fix-delta reduction.

  TODO: CoFixpoints *)

Section Wcbv.
  Context (Σ : global_declarations) (Γ : context).
  (* The local context is fixed: we are only doing weak reductions *)

  Inductive eval : term -> term -> Prop :=
  (** Reductions *)
  | eval_box l : eval (mktApp tBox l) tBox

  (** Beta *)
  | eval_beta f na t b a a' l res :
      eval f (tLambda na t b) ->
      eval a a' ->
      eval (mkApps (subst0 a' b) l) res ->
      eval (tApp f (a :: l)) res

  (** Let *)
  | eval_zeta na b0 b0' t b1 res :
      eval b0 b0' ->
      eval (subst0 b0' b1) res ->
      eval (tLetIn na b0 t b1) res

  (** Local variables: defined or undefined *)
  | eval_rel_def i (isdecl : i < List.length Γ) body res :
      (safe_nth Γ (exist _ i isdecl)).(decl_body) = Some body ->
      eval (lift0 (S i) body) res ->
      eval (tRel i) res

  | eval_rel_undef i (isdecl : i < List.length Γ) :
      (safe_nth Γ (exist _ i isdecl)).(decl_body) = None ->
      eval (tRel i) (tRel i)

  (** Case *)
  | eval_iota ind pars discr c u args p brs res :
      eval discr (mkApps (tConstruct ind c u) args) ->
      eval (iota_red pars c args brs) res ->
      eval (tCase (ind, pars) p discr brs) res

  (** Fix unfolding, with guard *)
  | eval_fix mfix idx args args' narg fn res :
      unfold_fix mfix idx = Some (narg, fn) ->
      Forall2 eval args args' -> (* FIXME should we reduce the args after the recursive arg here? *)
      is_constructor narg args' = true ->
      eval (mkApps fn args') res ->
      eval (mkApps (tFix mfix idx) args) res

  (** Constant unfolding *)
  | eval_delta c decl body (isdecl : declared_constant Σ c decl) u res :
      decl.(cst_body) = Some body ->
      eval (subst_instance_constr u body) res ->
      eval (tConst c u) res

  (** Proj *)
  | eval_proj i pars arg discr args k u res :
      eval discr (mkApps (tConstruct i k u) args) ->
      eval (List.nth (pars + arg) args tDummy) res ->
      eval (tProj (i, pars, arg) discr) res

  (* TODO CoFix *)
  | eval_abs na M N : eval (tLambda na M N) (tLambda na M N)

  | eval_prod na b t b' t' :
      eval b b' -> eval t t' -> eval (tProd na b t) (tProd na b' t')

  | eval_ind_ i u : eval (tInd i u) (tInd i u)

  | eval_app_ind t i u l l' : l <> nil ->
      eval t (tInd i u) ->
      Forall2 eval l l' ->
      eval (tApp t l) (tApp (tInd i u) l')

  | eval_constr i k u :
      eval (tConstruct i k u) (tConstruct i k u)

  | eval_app_constr f i k u l l' : l <> nil ->
      eval f (tConstruct i k u) ->
      Forall2 eval l l' ->
      eval (tApp f l) (tApp (tConstruct i k u) l')

  (* | evar ev l l' : evals l l' -> eval (tEvar ev l) (tEvar ev l') *)
  | eval_evar ev l : eval (tEvar ev l) (tEvar ev l) (* Lets say it is a value for now *).

  (** The right induction principle for the nested [Forall] cases: *)

  Lemma eval_evals_ind :
    forall P : term -> term -> Prop,
      (forall l, P (mktApp tBox l) tBox) ->
      (forall (f : term) (na : name) (t b a a' : term) (l : list term) (res : term),
          eval f (tLambda na t b) ->
          P f (tLambda na t b) ->
          eval a a' -> P a a' ->
          eval (mkApps (b {0 := a'}) l) res -> P (mkApps (b {0 := a'}) l) res -> P (tApp f (a :: l)) res) ->

      (forall (na : name) (b0 b0' t b1 res : term),
          eval b0 b0' -> P b0 b0' -> eval (b1 {0 := b0'}) res -> P (b1 {0 := b0'}) res -> P (tLetIn na b0 t b1) res) ->

      (forall (i : nat) (isdecl : i < #|Γ|) (body res : term),
          decl_body (safe_nth Γ (exist (fun n : nat => n < #|Γ|) i isdecl)) = Some body ->
          eval ((lift0 (S i)) body) res -> P ((lift0 (S i)) body) res -> P (tRel i) res) ->

      (forall (i : nat) (isdecl : i < #|Γ|),
          decl_body (safe_nth Γ (exist (fun n : nat => n < #|Γ|) i isdecl)) = None -> P (tRel i) (tRel i)) ->

      (forall (ind : inductive) (pars : nat) (discr : term) (c : nat) (u : universe_instance)
              (args : list term) (p : term) (brs : list (nat * term)) (res : term),
          eval discr (mkApps (tConstruct ind c u) args) ->
          P discr (mkApps (tConstruct ind c u) args) ->
          eval (iota_red pars c args brs) res ->
          P (iota_red pars c args brs) res -> P (tCase (ind, pars) p discr brs) res) ->

      (forall (mfix : mfixpoint term) (idx : nat) (args args' : list term) (narg : nat) (fn res : term),
          unfold_fix mfix idx = Some (narg, fn) ->
          Forall2 eval args args' ->
          Forall2 P args args' ->
          is_constructor narg args' = true ->
          eval (mkApps fn args') res -> P (mkApps fn args') res -> P (mkApps (tFix mfix idx) args) res) ->

      (forall (c : ident) (decl : constant_body) (body : term),
          declared_constant Σ c decl ->
          forall (u : universe_instance) (res : term),
            cst_body decl = Some body ->
            eval (subst_instance_constr u body) res -> P (subst_instance_constr u body) res -> P (tConst c u) res) ->

      (forall (i : inductive) (pars arg : nat) (discr : term) (args : list term) (k : nat)
              (u : universe_instance) (res : term),
          eval discr (mkApps (tConstruct i k u) args) ->
          P discr (mkApps (tConstruct i k u) args) ->
          eval (nth (pars + arg) args tDummy) res ->
          P (nth (pars + arg) args tDummy) res -> P (tProj (i, pars, arg) discr) res) ->

      (forall (na : name) (M N : term), P (tLambda na M N) (tLambda na M N)) ->

      (forall (na : name) (M M' N N' : term),
          eval M M' -> eval N N' -> P M M' -> P N N' ->
          P (tProd na M N) (tProd na M' N')) ->

      (forall i u, P (tInd i u) (tInd i u)) ->

      (forall (f8 : term) (i : inductive) (u : universe_instance) (l l' : list term),
          l <> nil -> eval f8 (tInd i u) ->
          P f8 (tInd i u) -> Forall2 eval l l' -> Forall2 P l l' -> P (tApp f8 l) (tApp (tInd i u) l')) ->

      (forall i k u, P (tConstruct i k u) (tConstruct i k u)) ->

      (forall (f8 : term) (i : inductive) (k : nat) (u : universe_instance) (l l' : list term),
          l <> nil -> eval f8 (tConstruct i k u) ->
          P f8 (tConstruct i k u) -> Forall2 eval l l' -> Forall2 P l l' -> P (tApp f8 l) (tApp (tConstruct i k u) l')) ->

      (forall (ev : nat) (l : list term), P (tEvar ev l) (tEvar ev l)) ->

      forall t t0 : term, eval t t0 -> P t t0.
  Proof.
    intros P Hbox Hbeta Hlet Hreldef Hrelvar Hcase Hfix Hconst Hproj Hlam Hprod Hind Hindapp Hcstr Hcstrapp Hevar.
    fix eval_evals_ind 3. destruct 1;
             try match goal with [ H : _ |- _ ] =>
                             match type of H with
                               forall t t0, eval t t0 -> _ => fail 1
                             | _ => eapply H
                             end end; eauto.
    clear H1 H2.
    revert args args' H0. fix aux 3. destruct 1. constructor; auto.
    constructor. now apply eval_evals_ind. now apply aux.
    revert l l' H H1. fix aux 4. destruct 2. contradiction. constructor.
    now apply eval_evals_ind.
    destruct l. inv H2; constructor.
    now apply aux.
    revert l l' H H1. fix aux 4. destruct 2. contradiction. constructor.
    now apply eval_evals_ind. destruct l. inv H2; constructor. now apply aux.
  Defined.

  (** Characterization of values for this reduction relation:
      Basically atoms (constructors, inductives, products (FIXME sorts missing))
      and de Bruijn variables and lambda abstractions. Closed values disallow
      de Bruijn variables. *)

  Inductive value : term -> Prop :=
  | value_tBox : value tBox
  | value_tRel i : value (tRel i)
  | value_tEvar ev l : value (tEvar ev l)
  | value_tLam na t b : value (tLambda na t b)
  | value_tProd na t u : value (tProd na t u)
  | value_tInd i k l : List.Forall value l -> value (mkApps (tInd i k) l)
  | value_tConstruct i k u l : List.Forall value l -> value (mkApps (tConstruct i k u) l).

  Lemma value_values_ind : forall P : term -> Prop,
      (P tBox) ->
       (forall i : nat, P (tRel i)) ->
       (forall (ev : nat) (l : list term), P (tEvar ev l)) ->
       (forall (na : name) (t b : term), P (tLambda na t b)) ->
       (forall (na : name) (t u : term), P (tProd na t u)) ->
       (forall (i : inductive) (k : universe_instance) l, List.Forall value l -> List.Forall P l -> P (mkApps (tInd i k) l)) ->
       (forall (i : inductive) (k : nat) (u : universe_instance) (l : list term),
        List.Forall value l -> List.Forall P l -> P (mkApps (tConstruct i k u) l)) -> forall t : term, value t -> P t.
  Proof.
    intros P ???????.
    fix value_values_ind 2. destruct 1. 1-4:clear value_values_ind; auto.
    apply H3. apply H4. apply H6.
    revert l H6. fix aux 2. destruct 1. constructor; auto.
    constructor. now apply value_values_ind. now apply aux.
    apply H5. apply H6.
    revert l H6. fix aux 2. destruct 1. constructor; auto.
    constructor. now apply value_values_ind. now apply aux.
  Defined.

  (** The codomain of evaluation is only values:
      It means no redex can remain at the head of an evaluated term. *)

  Lemma Forall2_right {A B} (P : B -> Prop) (l : list A) (l' : list B) :
    Forall2 (fun x y => P y) l l' -> List.Forall (fun x => P x) l'.
  Proof.
    induction 1; constructor; auto.
  Qed.

  Lemma Forall2_non_nil {A B} (P : A -> B -> Prop) (l : list A) (l' : list B) :
    Forall2 P l l' -> l <> nil -> l' <> nil.
  Proof.
    induction 1; congruence.
  Qed.

  Lemma eval_to_value e e' : eval e e' -> value e'.
  Proof.
    induction 1 using eval_evals_ind; simpl; auto using value.
    eapply (value_tInd i u []); try constructor.
    pose proof (value_tInd i u l'). forward H3.
    apply (Forall2_right _ _ _ H2).
    rewrite mkApps_tApp in H3; auto. simpl; auto. eauto using Forall2_non_nil.
    eapply (value_tConstruct i k u []); try constructor.
    pose proof (value_tConstruct i k u l'). forward H3.
    apply (Forall2_right _ _ _ H2).
    rewrite mkApps_tApp in H3; auto. simpl; auto. eauto using Forall2_non_nil.
  Qed.

  (** Evaluation preserves closedness: *)
  Lemma eval_closed : forall n t u, closedn n t = true -> eval t u -> closedn n u = true.
  Proof.
    induction 2 using eval_evals_ind; simpl in *; eauto. eapply IHeval3.
    admit.
  Admitted. (* FIXME complete *)

End Wcbv.
