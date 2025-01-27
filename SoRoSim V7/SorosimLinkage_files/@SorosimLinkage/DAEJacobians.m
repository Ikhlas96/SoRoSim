function [ID,tau,e,dID_dq,dID_dqd,dID_dqdd,dID_dlambda,dtau_dq,dtau_dqd,dtau_du,de_dq,de_dqd,de_dqdd,daction_dq,daction_dqd] = DAEJacobians(Linkage,q,qd,qdd,u,lambda,index)

%For index 1 DAE e=e(q,qd,qdd). For index 3 DAE e=e(q)

N    = Linkage.N;
ndof = Linkage.ndof;
nsig = Linkage.nsig; %Total number of computational points
nj   = Linkage.nj;   %Total number of joints (rigid and virtual soft joints (nip-1))

if Linkage.Actuated
    nact = Linkage.nact;
    if Linkage.CAI
        [~,daction_dx] = CustomActuatorInput(Linkage,[q;qd]); %x is qqd
        daction_dq  = daction_dx(:,1:ndof);
        daction_dqd = daction_dx(:,ndof+1:2*ndof);
    else
        daction_dq  = 0; %0 is better than zeros(nact,ndof)
        daction_dqd = 0;
    end
end

ID          = zeros(ndof,1);
dID_dq      = zeros(ndof,ndof);
dID_dqd     = zeros(ndof,ndof);
dID_dqdd    = zeros(ndof,ndof); %same as M

tau         = zeros(ndof,1);
dtau_dq     = zeros(ndof,ndof);
dtau_dqd    = zeros(ndof,ndof);
dtau_du     = zeros(ndof,nact); %same as B

if Linkage.nCLj>1
    nCLp = Linkage.CLprecompute.nCLp;

    dID_dlambda = zeros(ndof,nCLp); %same as -A'

    e       = zeros(nCLp,1);
    de_dq   = zeros(nCLp,ndof);
    de_dqd  = zeros(nCLp,ndof);
    de_dqdd = zeros(nCLp,ndof); %A
else
    e = []; de_dq = []; de_dqd = []; de_dqdd = [];
end

Fk = zeros(6*nsig,1); %External point force at every significant point

%% Forward kinematic pass: evaluate kinematic, and derivatives terms at every virtual joint and significant points

h = zeros(1,nj);            %Joint length. h=1 for rigid joints
Omega = zeros(6,nj);        %Joint twist
Z = zeros(6*nj,ndof);       %Joint basis. Z=Phi for rigid joints (sparse matrix, can we avoid?)
gstep = zeros(4*nj,4);      %Linkageansformation from X_alpha to X_alpha+1 (0 to 1 for rigid joints)
Adgstepinv = zeros(6*nj,6); %As the name says!
T = zeros(6*nj,6);          %Tangent vector at each joint (T(Omega))

S = zeros(6*nj,ndof);         %S is joint motion subspace (sparse matrix for a reason)
Sd = zeros(6*nj,ndof);        %Sd is time derivative of joint motion subspace (sparse matrix for a reason)
dS_dq_qd = zeros(6*nj,ndof);  %as the name says (sparse matrix for a reason)
dS_dq_qdd = zeros(6*nj,ndof); %as the name says (sparse matrix for a reason)
dSd_dq_qd = zeros(6*nj,ndof); %as the name says (sparse matrix for a reason)

R = zeros(6*nj,ndof); %relative joint velocity gradient wrt q (sparse matrix for a reason)
L = zeros(6*nj,ndof); %relative joint acceleration gradient wrt q (sparse matrix for a reason)
Q = zeros(6*nj,ndof); %L - gravity gravity derivative wrt q at joint (sparse matrix for a reason)
Y = zeros(6*nj,ndof); %relative joint acceleration gradient wrt qdot R+(.) (sparse matrix for a reason)

f = zeros(4,nj);            %function of theta, required for the computations of Tangent operator
fd = zeros(4,nj);           %required for the derivative of Tangent operator
adjOmegap = zeros(24*nj,6); %Powers of adjOmega (1-4), used later

g = zeros(4*nsig,4);    %Fwd kinematics

J    = zeros(6*nsig,ndof); %Jacobian (J is S_B)
eta  = zeros(6*nsig,1);    %velocity twist
Jd   = zeros(6*nsig,ndof); %Jacobian dot (Jd is Sd_B)
etad = zeros(6*nsig,1);    %acceleration twist

R_B = zeros(6*nsig,ndof); %Joint velocity gradient wrt q
L_B = zeros(6*nsig,ndof); %Joint acceleration gradient wrt q
Q_B = zeros(6*nsig,ndof); %L_B - gravity gradient wrt q
Y_B = zeros(6*nsig,ndof); %Joint acceleration gradient wrt qd, Y_B = Jd+R_B

%For branched chain computation
g_tip = repmat(eye(4),N,1);

J_tip    = zeros(N*6,ndof);
eta_tip  = zeros(N*6,1);
Jd_tip   = zeros(N*6,ndof);
etad_tip = zeros(N*6,1);

R_Btip = zeros(N*6,ndof);
L_Btip = zeros(N*6,ndof);
Q_Btip = zeros(N*6,ndof);
Y_Btip = zeros(N*6,ndof);


dof_start = 1; %starting dof of current rod
i_sig = 1;     %current computational point index
ij = 1;        %current virtual joint index

iLpre = Linkage.iLpre;
g_ini = Linkage.g_ini;

for i=1:N

    G = Linkage.G;
    if ~Linkage.Gravity
        G = G*0;
    elseif Linkage.UnderWater %G is reduced by a factor of 1-rho_water/rho_body
        G = G*(1-Linkage.Rho_water/Linkage.VLinks(Linkage.LinkIndex(i)).Rho);
    end

    if iLpre(i)>0
        g_here = g_tip((iLpre(i)-1)*4+1:iLpre(i)*4,:)*g_ini((i-1)*4+1:i*4,:);
        Ad_g_ini_inv = dinamico_Adjoint(ginv(g_ini((i-1)*4+1:i*4,:)));

        J_here    = Ad_g_ini_inv*J_tip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        eta_here  = Ad_g_ini_inv*eta_tip((iLpre(i)-1)*6+1:iLpre(i)*6);
        Jd_here   = Ad_g_ini_inv*Jd_tip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        etad_here = Ad_g_ini_inv*etad_tip((iLpre(i)-1)*6+1:iLpre(i)*6);

        R_Bhere = Ad_g_ini_inv*R_Btip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        L_Bhere = Ad_g_ini_inv*L_Btip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        Q_Bhere = Ad_g_ini_inv*Q_Btip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        Y_Bhere = Ad_g_ini_inv*Q_Btip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
    else
        g_here = g_ini((i-1)*4+1:i*4,:);

        J_here    = zeros(6,ndof);
        eta_here  = zeros(6,1);
        Jd_here   = zeros(6,ndof);
        etad_here = zeros(6,1);

        R_Bhere = zeros(6,ndof);
        L_Bhere = zeros(6,ndof);
        Q_Bhere = zeros(6,ndof);
        Y_Bhere = zeros(6,ndof);
    end

    %Joint

    %0 of joint
    g((i_sig-1)*4+1:4*i_sig,:) = g_here;

    J((i_sig-1)*6+1:6*i_sig,:)    = J_here;
    eta((i_sig-1)*6+1:6*i_sig,:)  = eta_here;
    Jd((i_sig-1)*6+1:6*i_sig,:)   = Jd_here;
    etad((i_sig-1)*6+1:6*i_sig,:) = etad_here;

    L_B((i_sig-1)*6+1:6*i_sig,:) = L_Bhere;
    R_B((i_sig-1)*6+1:6*i_sig,:) = R_Bhere;
    Q_B((i_sig-1)*6+1:6*i_sig,:) = Q_Bhere;
    Y_B((i_sig-1)*6+1:6*i_sig,:) = Y_Bhere;

    dof_here  = Linkage.CVRods{i}(1).dof;
    dofs_here = dof_start:dof_start+dof_here-1;

    Phi_here = Linkage.CVRods{i}(1).Phi;
    xi_star  = Linkage.CVRods{i}(1).xi_star;
    h(ij) = 1;

    %computation of kinematic and differential kinematic quantities at the rigid joint
    %[Omega,Z,g,T,S,Sd,f,fd,adjOmegap,dSdq_qd,dSdq_qdd,dSddq_qd]=RigidJointDifferentialKinematics(Phi,xi_star,q,qd,qdd)
    [Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),gstep((ij-1)*4+1:4*ij,:),T((ij-1)*6+1:6*ij,:),S((ij-1)*6+1:6*ij,dofs_here),...
     Sd((ij-1)*6+1:6*ij,dofs_here),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),dS_dq_qd((ij-1)*6+1:6*ij,dofs_here),...
     dS_dq_qdd((ij-1)*6+1:6*ij,dofs_here),dSd_dq_qd((ij-1)*6+1:6*ij,dofs_here)] = RigidJointDifferentialKinematics_mex(Phi_here,xi_star,q(dofs_here),qd(dofs_here),qdd(dofs_here));
    Adgstepinv((ij-1)*6+1:6*ij,:) = dinamico_Adjoint(ginv(gstep((ij-1)*4+1:4*ij,:)));

    eta_plus_here  = eta_here+S((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here);
    etad_plus_here = etad_here+S((ij-1)*6+1:6*ij,dofs_here)*qdd(dofs_here)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here)+Sd((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here);
    
    R((ij-1)*6+1:6*ij,dofs_here) = dinamico_adj(eta_plus_here)*S((ij-1)*6+1:6*ij,dofs_here)+dS_dq_qd((ij-1)*6+1:6*ij,dofs_here);
    L((ij-1)*6+1:6*ij,dofs_here) = dinamico_adj(etad_plus_here)*S((ij-1)*6+1:6*ij,dofs_here)+dinamico_adj(eta_plus_here)*R((ij-1)*6+1:6*ij,dofs_here)...
                                  +dinamico_adj(eta_here)*dS_dq_qd((ij-1)*6+1:6*ij,dofs_here)+dSd_dq_qd((ij-1)*6+1:6*ij,dofs_here)+dS_dq_qdd((ij-1)*6+1:6*ij,dofs_here); % L is Q without gravity
    Q((ij-1)*6+1:6*ij,dofs_here) = L((ij-1)*6+1:6*ij,dofs_here)-dinamico_adj(dinamico_Adjoint(ginv(g_here))*G)*S((ij-1)*6+1:6*ij,dofs_here);
    Y((ij-1)*6+1:6*ij,dofs_here) = R((ij-1)*6+1:6*ij,dofs_here)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here)+Sd((ij-1)*6+1:6*ij,dofs_here);
    
    % from 0 to 1 of rigid joint
    g_here  = g_here*gstep((ij-1)*4+1:4*ij,:);

    J_here    = Adgstepinv((ij-1)*6+1:6*ij,:)*(J_here+S((ij-1)*6+1:6*ij,:));
    eta_here  = Adgstepinv((ij-1)*6+1:6*ij,:)*(eta_plus_here);
    Jd_here   = Adgstepinv((ij-1)*6+1:6*ij,:)*(Jd_here+Sd((ij-1)*6+1:6*ij,:)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here));
    etad_here = Adgstepinv((ij-1)*6+1:6*ij,:)*(etad_plus_here);

    R_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(R_Bhere+R((ij-1)*6+1:6*ij,:));
    L_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(L_Bhere+L((ij-1)*6+1:6*ij,:));
    Q_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(Q_Bhere+Q((ij-1)*6+1:6*ij,:));
    Y_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(Y_Bhere+Y((ij-1)*6+1:6*ij,:));
    
    
    ij = ij+1;
    i_sig = i_sig+1;
    if ~Linkage.OneBasis %thinking about POD basis of Abdulaziz
        dof_start = dof_start+dof_here;
    end

    if Linkage.VLinks(Linkage.LinkIndex(i)).linktype=='r'
        %joint to CM
        gi = Linkage.VLinks(Linkage.LinkIndex(i)).gi;
        Ad_gi_inv = dinamico_Adjoint(ginv(gi));
        
        g_here  = g_here*gi;

        J_here    = Ad_gi_inv*J_here;
        eta_here  = Ad_gi_inv*eta_here;
        Jd_here   = Ad_gi_inv*Jd_here;
        etad_here = Ad_gi_inv*etad_here;
    
        R_Bhere = Ad_gi_inv*R_Bhere;
        L_Bhere = Ad_gi_inv*L_Bhere;
        Q_Bhere = Ad_gi_inv*Q_Bhere;
        Y_Bhere = Ad_gi_inv*Y_Bhere;
        

        %CM is a significant point
        g((i_sig-1)*4+1:4*i_sig,:) = g_here;

        J((i_sig-1)*6+1:6*i_sig,:)    = J_here;
        eta((i_sig-1)*6+1:6*i_sig,:)  = eta_here;
        Jd((i_sig-1)*6+1:6*i_sig,:)   = Jd_here;
        etad((i_sig-1)*6+1:6*i_sig,:) = etad_here;
    
        L_B((i_sig-1)*6+1:6*i_sig,:) = L_Bhere;
        R_B((i_sig-1)*6+1:6*i_sig,:) = R_Bhere;
        Q_B((i_sig-1)*6+1:6*i_sig,:) = Q_Bhere;
        Y_B((i_sig-1)*6+1:6*i_sig,:) = Y_Bhere;

        i_sig = i_sig+1;

        %CM to tip
        gf = Linkage.VLinks(Linkage.LinkIndex(i)).gf; 
        Ad_gf_inv = dinamico_Adjoint(ginv(gf));

        g_here  = g_here*gf;

        J_here    = Ad_gf_inv*J_here;
        eta_here  = Ad_gf_inv*eta_here;
        Jd_here   = Ad_gf_inv*Jd_here;
        etad_here = Ad_gf_inv*etad_here;
    
        R_Bhere = Ad_gf_inv*R_Bhere;
        L_Bhere = Ad_gf_inv*L_Bhere;
        Q_Bhere = Ad_gf_inv*Q_Bhere;
        Y_Bhere = Ad_gf_inv*Y_Bhere;
    end

    for j=1:Linkage.VLinks(Linkage.LinkIndex(i)).npie-1 %will run only if npie>1, ie for soft links

        dof_here  = Linkage.CVRods{i}(j+1).dof;
        dofs_here = dof_start:dof_start+dof_here-1;
        
        
        ld = Linkage.VLinks(Linkage.LinkIndex(i)).ld{j};
        xi_star = Linkage.CVRods{i}(j+1).xi_star;
        Xs      = Linkage.CVRods{i}(j+1).Xs;
        nip     = Linkage.CVRods{i}(j+1).nip;
        h(ij:ij+nip-2) = (Xs(2:end)-Xs(1:end-1))*ld;
        
        gi = Linkage.VLinks(Linkage.LinkIndex(i)).gi{j}; %X=1 of joint to first quadrature point at X=0 of the rod
        Ad_gi_inv = dinamico_Adjoint(ginv(gi)); %transformation from X=1 of joint or X=Ld of previous division to the X=0 of next division
        
        g_here  = g_here*gi;

        J_here    = Ad_gi_inv*J_here;
        eta_here  = Ad_gi_inv*eta_here;
        Jd_here   = Ad_gi_inv*Jd_here;
        etad_here = Ad_gi_inv*etad_here;
    
        R_Bhere = Ad_gi_inv*R_Bhere;
        L_Bhere = Ad_gi_inv*L_Bhere;
        Q_Bhere = Ad_gi_inv*Q_Bhere;
        Y_Bhere = Ad_gi_inv*Y_Bhere;

        g((i_sig-1)*4+1:4*i_sig,:) = g_here;

        J((i_sig-1)*6+1:6*i_sig,:)    = J_here;
        eta((i_sig-1)*6+1:6*i_sig,:)  = eta_here;
        Jd((i_sig-1)*6+1:6*i_sig,:)   = Jd_here;
        etad((i_sig-1)*6+1:6*i_sig,:) = etad_here;
    
        L_B((i_sig-1)*6+1:6*i_sig,:) = L_Bhere;
        R_B((i_sig-1)*6+1:6*i_sig,:) = R_Bhere;
        Q_B((i_sig-1)*6+1:6*i_sig,:) = Q_Bhere;
        Y_B((i_sig-1)*6+1:6*i_sig,:) = Y_Bhere;

        i_sig  = i_sig+1;

        for ii=1:nip-1 %%%%%%%%%%%%HERE
            
            if Linkage.Z_order==4
                xi_star_Z1 = xi_star(6*(ii-1)+1:6*ii,2);
                xi_star_Z2 = xi_star(6*(ii-1)+1:6*ii,3);
                Phi_Z1 = Linkage.CVRods{i}(j+1).Phi_Z1(6*(ii-1)+1:6*ii,:);
                Phi_Z2 = Linkage.CVRods{i}(j+1).Phi_Z2(6*(ii-1)+1:6*ii,:);

                %[Omega,Z,g,T,S,Sd,f,fd,adjOmegap,dSdq_qd,dSdq_qdd,dSddq_qd]=SoftJointDifferentialKinematics_Z4(h,Phi_Z1,Phi_Z2,xi_star_Z1,xi_star_Z2,q,qd,qdd)
                [Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),gstep((ij-1)*4+1:4*ij,:),T((ij-1)*6+1:6*ij,:),S((ij-1)*6+1:6*ij,dofs_here),...
                 Sd((ij-1)*6+1:6*ij,dofs_here),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),dS_dq_qd((ij-1)*6+1:6*ij,dofs_here),...
                 dS_dq_qdd((ij-1)*6+1:6*ij,dofs_here),dSd_dq_qd((ij-1)*6+1:6*ij,dofs_here)] = SoftJointDifferentialKinematics_Z4_mex(h(ij),Phi_Z1,Phi_Z2,xi_star_Z1,xi_star_Z2,q(dofs_here),qd(dofs_here),qdd(dofs_here));
                Adgstepinv((ij-1)*6+1:6*ij,:) = dinamico_Adjoint(ginv(gstep((ij-1)*4+1:4*ij,:)));
            else % order 2
                xi_star_Z  = xi_star(6*(ii-1)+1:6*ii,4);
                Phi_Z = Linkage.CVRods{i}(j+1).Phi_Z(6*(ii-1)+1:6*ii,:);
                
                %[Omega,Z,g,T,S,Sd,f,fd,adjOmegap,dSdq_qd,dSdq_qdd,dSddq_qd]=SoftJointDifferentialKinematics_Z2(h,Phi_Z,xi_star_Z,q,qd,qdd)
                [Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),gstep((ij-1)*4+1:4*ij,:),T((ij-1)*6+1:6*ij,:),S((ij-1)*6+1:6*ij,dofs_here),...
                 Sd((ij-1)*6+1:6*ij,dofs_here),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),dS_dq_qd((ij-1)*6+1:6*ij,dofs_here),...
                 dS_dq_qdd((ij-1)*6+1:6*ij,dofs_here),dSd_dq_qd((ij-1)*6+1:6*ij,dofs_here)] = SoftJointDifferentialKinematics_Z4_mex(h(ij),Phi_Z,xi_star_Z,q(dofs_here),qd(dofs_here),qdd(dofs_here));
                Adgstepinv((ij-1)*6+1:6*ij,:) = dinamico_Adjoint(ginv(gstep((ij-1)*4+1:4*ij,:)));
            end
           
            eta_plus_here  = eta_here+S((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here);
            etad_plus_here = etad_here+S((ij-1)*6+1:6*ij,dofs_here)*qdd(dofs_here)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here)+Sd((ij-1)*6+1:6*ij,dofs_here)*qd(dofs_here);
            
            R((ij-1)*6+1:6*ij,dofs_here) = dinamico_adj(eta_plus_here)*S((ij-1)*6+1:6*ij,dofs_here)+dS_dq_qd((ij-1)*6+1:6*ij,dofs_here);
            L((ij-1)*6+1:6*ij,dofs_here) = dinamico_adj(etad_plus_here)*S((ij-1)*6+1:6*ij,dofs_here)+dinamico_adj(eta_plus_here)*R((ij-1)*6+1:6*ij,dofs_here)...
                                          +dinamico_adj(eta_here)*dS_dq_qd((ij-1)*6+1:6*ij,dofs_here)+dSd_dq_qd((ij-1)*6+1:6*ij,dofs_here)+dS_dq_qdd((ij-1)*6+1:6*ij,dofs_here); % L is Q without gravity
            Q((ij-1)*6+1:6*ij,dofs_here) = L((ij-1)*6+1:6*ij,dofs_here)-dinamico_adj(dinamico_Adjoint(ginv(g_here))*G)*S((ij-1)*6+1:6*ij,dofs_here);
            Y((ij-1)*6+1:6*ij,dofs_here) = R((ij-1)*6+1:6*ij,dofs_here)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here)+Sd((ij-1)*6+1:6*ij,dofs_here);
            
            g_here  = g_here*gstep((ij-1)*4+1:4*ij,:);

            J_here    = Adgstepinv((ij-1)*6+1:6*ij,:)*(J_here+S((ij-1)*6+1:6*ij,:));
            eta_here  = Adgstepinv((ij-1)*6+1:6*ij,:)*(eta_plus_here);
            Jd_here   = Adgstepinv((ij-1)*6+1:6*ij,:)*(Jd_here+Sd((ij-1)*6+1:6*ij,:)+dinamico_adj(eta_here)*S((ij-1)*6+1:6*ij,dofs_here));
            etad_here = Adgstepinv((ij-1)*6+1:6*ij,:)*(etad_plus_here);
        
            R_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(R_Bhere+R((ij-1)*6+1:6*ij,:));
            L_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(L_Bhere+L((ij-1)*6+1:6*ij,:));
            Q_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(Q_Bhere+Q((ij-1)*6+1:6*ij,:));
            Y_Bhere = Adgstepinv((ij-1)*6+1:6*ij,:)*(Y_Bhere+Y((ij-1)*6+1:6*ij,:));

            g((i_sig-1)*4+1:4*i_sig,:) = g_here;

            J((i_sig-1)*6+1:6*i_sig,:)    = J_here;
            eta((i_sig-1)*6+1:6*i_sig,:)  = eta_here;
            Jd((i_sig-1)*6+1:6*i_sig,:)   = Jd_here;
            etad((i_sig-1)*6+1:6*i_sig,:) = etad_here;
        
            L_B((i_sig-1)*6+1:6*i_sig,:) = L_Bhere;
            R_B((i_sig-1)*6+1:6*i_sig,:) = R_Bhere;
            Q_B((i_sig-1)*6+1:6*i_sig,:) = Q_Bhere;
            Y_B((i_sig-1)*6+1:6*i_sig,:) = Y_Bhere;

            ij = ij+1;
            i_sig = i_sig+1;

        end

        gf = Linkage.VLinks(Linkage.LinkIndex(i)).gf{j};
        Ad_gf_inv = dinamico_Adjoint(ginv(gf));

        g_here  = g_here*gf;

        J_here    = Ad_gf_inv*J_here;
        eta_here  = Ad_gf_inv*eta_here;
        Jd_here   = Ad_gf_inv*Jd_here;
        etad_here = Ad_gf_inv*etad_here;
    
        R_Bhere = Ad_gf_inv*R_Bhere;
        L_Bhere = Ad_gf_inv*L_Bhere;
        Q_Bhere = Ad_gf_inv*Q_Bhere;
        Y_Bhere = Ad_gf_inv*Y_Bhere;

        if ~Linkage.OneBasis
            dof_start = dof_start+dof_here;
        end
    end

    g_tip((i-1)*4+1:i*4,:) = g_here;

    J_tip((i-1)*6+1:i*6,:)    = J_here;
    eta_tip((i-1)*6+1:i*6,:)  = eta_here;
    Jd_tip((i-1)*6+1:i*6,:)   = Jd_here;
    etad_tip((i-1)*6+1:i*6,:) = etad_here;

    R_Btip((i-1)*6+1:i*6,:) = R_Bhere;
    L_Btip((i-1)*6+1:i*6,:) = L_Bhere;
    Q_Btip((i-1)*6+1:i*6,:) = Q_Bhere;
    Y_Btip((i-1)*6+1:i*6,:) = Y_Bhere;

end

%% Point Wrench 

for ip=1:Linkage.np
    Fp_here = Linkage.Fp_vec{ip}(0);
    i_sig = Linkage.Fp_sig(ip);
    I_theta = diag([1 1 1 0 0 0]);

    if ~Linkage.LocalWrench(i) %if in the global frame
        g_here = g((i_sig-1)*4+1:i_sig*4,:);
        g_here(1:3,4) = zeros(3,1); %only rotational part
        Fp_here = (dinamico_Adjoint(g_here))'*Fp_here; %rotated into the local frame. Adj' = coAdj^-1
        dFp_dq = dinamico_coadj(Fp_here)*I_theta*J((i_sig-1)*6+1:i_sig*6,:);
        dID_dq = dID_dq-J((i_sig-1)*6+1:i_sig*6,:)'*dFp_dq; %external force hence negative
    end

    Fk((i_sig-1)*6+1:i_sig*6) = Fk((i_sig-1)*6+1:i_sig*6)+Fp_here;
end
%% Closed Chain Constraint

A = zeros(Linkage.CLprecompute.nCLp,ndof);
e = zeros(Linkage.CLprecompute.nCLp,1);
de_dq = zeros(Linkage.CLprecompute.nCLp,ndof);
if index==1
    Ad = zeros(Linkage.CLprecompute.nCLp,ndof);
    de_dqd = zeros(Linkage.CLprecompute.nCLp,ndof);
else
    de_dqd = 0;
    de_dqdd = 0;
end

il_start = 1; %starting index of current closed chain joint lambda

for iCLj=1:Linkage.nCLj
    
    i_sigA = Linkage.CLprecompute.i_sigA(iCLj);
    i_sigB = Linkage.CLprecompute.i_sigB(iCLj);
    Phi_p = Linkage.CLprecompute.Phi_p{iCLj};
    nl = size(Phi_p,2); %total number of constraint forces in the iCLj th closed chain joint
    
    if i_sigA>0
        %Transformation from computational point to CLj
        if Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLA(iCLj))).linktype=='s'
            g_sigA2CLj = Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLA(iCLj))).gf{end}*Linkage.gACLj{iCLj};
        else
            g_sigA2CLj = Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLA(iCLj))).gf*Linkage.gACLj{iCLj};
        end
        gA = g((i_sigA-1)*4+1:i_sigA*4,:)*g_sigA2CLj;
        JA = dinamico_Adjoint(ginv(g_sigA2CLj))*J((i_sigA-1)*6+1:i_sigA*6,:);
        JdA = dinamico_Adjoint(ginv(g_sigA2CLj))*Jd((i_sigA-1)*6+1:i_sigA*6,:);
    else %if ground
        gA = Linkage.gACLj{iCLj};
        JA = zeros(6,ndof);
    end

    if i_sigB>0
        %Transformation from computational point to CLj
        if Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLB(iCLj))).linktype=='s'
            g_sigB2CLj = Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLB(iCLj))).gf{end}*Linkage.gBCLj{iCLj};
        else
            g_sigB2CLj = Linkage.VLinks(Linkage.LinkIndex(Linkage.iCLB(iCLj))).gf*Linkage.gBCLj{iCLj};
        end
        gB = g((i_sigB-1)*4+1:i_sigB*4,:)*g_sigB2CLj;
        JB = dinamico_Adjoint(ginv(g_sigB2CLj))*J((i_sigB-1)*6+1:i_sigB*6,:);
    else %if ground
        gB = Linkage.gBCLj{iCLj};
        JB = zeros(6,ndof);
    end
    
    %constraint force is in the B frame. Hence we need to bring all to B frame
    gBA = ginv(gB)*gA;
    OmegaBA = piecewise_logmap(gBA); %twist vector from B to A in R^6
    Adj_gBA = dinamico_Adjoint(gBA);
    diffJAB = Adj_gBA*JA-JB; %in B frame

    [~,T_RodBA] = variable_expmap_gTg_mex(OmegaBA); %Tangent operator of the twist vector

    A(il_start:il_start+nl-1,:) = Phi_p'*diffJAB;
    e(il_start:il_start+nl-1) = Phi_p'*OmegaBA;
    de_dq(il_start:il_start+nl-1,:) = Phi_p'*(T_RodBA\diffJAB);

    F_lambda = Phi_p*lambda(il_start:il_start+nl-1); %Note that -F_lambda acts on B

    if i_sigA>0
        FlA = dinamico_coAdjoint(g_sigA2CLj)*Adj_gBA'*F_lambda; %+F_lambda at B is first transformed to A (Adj_gBA' is coAdj_gAB) then to the computational point
        Fk((i_sigA-1)*6+1:i_sigA*6) = Fk((i_sigA-1)*6+1:i_sigA*6)+FlA;
        dFlA_dq = -Adj_gBA'*dinamico_coadjbar(F_lambda)*diffJAB; %Adj_gBA'= coAdj_gBA^-1
        dID_dq = dID_dq-J((i_sigA-1)*6+1:i_sigA*6,:)'*dFlA_dq; %external force hence negative
    end

    if i_sigB>0
        FlB = -dinamico_coAdjoint(g_sigB2CLj)*F_lambda; %bringing from CLj to computational point
        Fk((i_sigB-1)*6+1:i_sigB*6) = Fk((i_sigB-1)*6+1:i_sigB*6)+FlB;
    end
    
    il_start = il_start+nl;
end

%A should be FULL ROW RANK Matrix. Otherwise Problem!

% A possible fix below (needs more work)
% if rank(A)<size(A,1) %Have to take care of this
%     [~,iRows] = LIRows(A); 
%     e         = e(iRows); %iRows are the linearly independent rows of A. Comment this for some
%     de_dq     = de_dq(iRows,:);
% end

%% Custom External Force

if Linkage.CEF
    [Fext,dFext_dq]  = CustomExtForce(Linkage,q,g,J); %should be point wrench in local frame and its derivatives
    Fk = Fk+Fext;
    for i_sig=1:Linkage.nsig
        dID_dq = dID_dq-J((i_sig-1)*6+1:i_sig*6,:)'*dFext_dq((i_sig-1)*6+1:i_sig*6,:);
    end
end

%% Backward Pass

%Start from the last link, computationl point, joint and dof
i_sig = nsig;
ij = nj;
dof_start = ndof;

M_C_tip = zeros(N*6,6);
F_C_tip = zeros(N*6,1);
P_S_tip = zeros(N*6,ndof);
U_S_tip = zeros(N*6,ndof);

for i=N:-1:1 %backwards

    M_C = M_C_tip(6*(i-1)+1:6*i,:);
    F_C = F_C_tip(6*(i-1)+1:6*i);
    P_S = P_S_tip(6*(i-1)+1:6*i,:);
    U_S = U_S_tip(6*(i-1)+1:6*i,:);
    
    G = Linkage.G;
    if ~Linkage.Gravity
        G = G*0;
    elseif Linkage.UnderWater %G is reduced by a factor of 1-rho_water/rho_body
        G=G*(1-Linkage.Rho_water/Linkage.VLinks(Linkage.LinkIndex(i)).Rho);
    end
    
    if Linkage.VLinks(Linkage.LinkIndex(i)).linktype=='r'
        %tip to CM
        gf        = Linkage.VLinks(Linkage.LinkIndex(i)).gf; 
        Ad_gf_inv = dinamico_Adjoint(ginv(gf));
        coAd_gf   = Ad_gf_inv';
        
        M_C = coAd_gf*M_C*Ad_gf_inv;
        F_C = coAd_gf*F_C;
        P_S = coAd_gf*P_S;
        U_S = coAd_gf*U_S;

        i_sig = i_sig-1;

        %CM to base
        gi        = Linkage.VLinks(Linkage.LinkIndex(i)).gi; 
        Ad_gi_inv = dinamico_Adjoint(ginv(gi));
        coAd_gi   = Ad_gi_inv';
        
        M_ap1 = Linkage.VLinks(Linkage.LinkIndex(i)).M; %at alpha + 1: ap1
        F_ap1 = -M_ap1*dinamico_Adjoint(ginv(g(i_sig*4+1:4*(i_sig+1),:)))*G; %negative due to external force
        F_ap1 = F_ap1-Fk(i_sig*6+1:6*(i_sig+1)); %adding contributions of external point forces

        M_C = coAd_gi*(M_ap1+M_C)*Ad_gi_inv;
        F_C = coAd_gi*(F_ap1+F_C);
        P_S = coAd_gi*P_S;
        U_S = coAd_gi*U_S;

        %at X=1 of the rigid joint 
        M_ap1 = zeros(6,6); %at base
        F_ap1 = zeros(6,1);
    else
        for j=Linkage.VLinks(Linkage.LinkIndex(i)).npie-1:-1:1

            gf        = Linkage.VLinks(Linkage.LinkIndex(i)).gf{j}; 
            Ad_gf_inv = dinamico_Adjoint(ginv(gf));
            coAd_gf   = Ad_gf_inv';
            
            M_C = coAd_gf*M_C*Ad_gf_inv;
            F_C = coAd_gf*F_C;
            P_S = coAd_gf*P_S;
            U_S = coAd_gf*U_S;

            dof_here = Linkage.CVRods{i}(j+1).dof;
            dofs_here = dof_start-dof_here+1:dof_start;
            Ws = Linkage.CVRods{i}(j+1).Ws;
            nip = Linkage.CVRods{i}(j+1).nip;
            i_sig = i_sig-1; %at X=ld

            for ii=nip-1:-1:1
            
                coAdgstep = Adgstepinv((ij-1)*6+1:6*ij,:)';
            
                M_ap1 = Ws(ii+1)*Linkage.CVRods{i}(2).Ms(ii*6+1:6*(ii+1),:); %at alpha + 1. multiplied with weight
                
                F_ap1 = -M_ap1*dinamico_Adjoint(ginv(g(i_sig*4+1:4*(i_sig+1),:)))*G; %note that next computational point is used
                F_ap1 = F_ap1-Fk(i_sig*6+1:6*(i_sig+1)); %external point forces
    
                M_C = coAdgstep*(M_ap1+M_C)*Adgstepinv((ij-1)*6+1:6*ij,:);
                F_C = coAdgstep*(F_ap1+F_C);
    
                %split to two steps to optimize computation
                P_S = coAdgstep*P_S;
                U_S = coAdgstep*U_S;
    
                P_S(:,dofs_here) = P_S(:,dofs_here)+dinamico_coadjbar(F_C)*S((ij-1)*6+1:6*ij,dofs_here);
                U_S(:,dofs_here) = U_S(:,dofs_here)+M_C*Q((ij-1)*6+1:6*ij,dofs_here);

                if Linkage.Z_order==4
                    Phi_Z1 = Linkage.CVRods{i}(j+1).Phi_Z1((ii-1)*6+1:6*ii,:);
                    Phi_Z2 = Linkage.CVRods{i}(j+1).Phi_Z2((ii-1)*6+1:6*ii,:);
        
                    dSTdq_FC = compute_dSTdqFC_Z4_mex(h(ij),Omega(:,ij),Phi_Z1,Phi_Z2,Z((ij-1)*6+1:6*ij,dofs_here),T((ij-1)*6+1:6*ij,:),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),F_C);
                else
                    dSTdq_FC = compute_dSTdqFC_Z2R_mex(h(ij),Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),T((ij-1)*6+1:6*ij,:),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),F_C);
                end

                dSTdq_FC_full = zeros(dof_here,ndof);
                dSTdq_FC_full(:,dofs_here) = dSTdq_FC;
                
                ID(dofs_here,:) = ID(dofs_here,:)+S((ij-1)*6+1:6*ij,dofs_here)'*F_C;
                dID_dq(dofs_here,:) = dID_dq(dofs_here,:)+dSTdq_FC_full+S((ij-1)*6+1:6*ij,dofs_here)'*(M_C*Q_B((i_sig-1)*6+1:6*i_sig,:)+U_S+P_S);
    
                i_sig = i_sig-1;
                ij = ij-1;
            
            end
            
            M_ap1 = Ws(1)*Linkage.CVRods{i}(2).Ms(1:6,:); %at X = 0 usually Ws is 0
            F_ap1 = -M_ap1*dinamico_Adjoint(ginv(g(i_sig*4+1:4*(i_sig+1),:)))*G;
            F_ap1 = F_ap1-Fk(i_sig*6+1:6*(i_sig+1)); %external point forces

            gi        = Linkage.VLinks(Linkage.LinkIndex(i)).gi{j}; %fixed transforamtion from X=0 of the rod to X=1 of joint
            Ad_gi_inv = dinamico_Adjoint(ginv(gi));
            coAd_gi   = Ad_gi_inv';
            
            M_C = coAd_gi*(M_ap1+M_C)*Ad_gi_inv;
            F_C = coAd_gi*(F_ap1+F_C);
            P_S = coAd_gi*P_S;
            U_S = coAd_gi*U_S;

            if ~Linkage.OneBasis
                dof_start=dof_start-dof_here;
            end
        end
        %at X=1 of the rigid joint 
        M_ap1 = zeros(6,6); 
        F_ap1 = zeros(6,1);
    end

    %joint
    dof_here = Linkage.CVRods{i}(1).dof;

    if dof_here>0
        dofs_here = dof_start-dof_here+1:dof_start;
        coAdgstep = Adgstepinv((ij-1)*6+1:6*ij,:)';
        
        M_C = coAdgstep*(M_ap1+M_C)*Adgstepinv((ij-1)*6+1:6*ij,:);
        F_C = coAdgstep*(F_ap1+F_C);

        %split to two steps to optimize computation
        P_S = coAdgstep*P_S;
        U_S = coAdgstep*U_S;
    
        P_S(:,dofs_here) = P_S(:,dofs_here)+dinamico_coadjbar(F_C)*S((ij-1)*6+1:6*ij,dofs_here);
        U_S(:,dofs_here) = U_S(:,dofs_here)+M_C*Q((ij-1)*6+1:6*ij,dofs_here);
    
        dSTdq_FC = compute_dSTdqFC_Z2R_mex(dof_here,Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),F_C);
        dSTdq_FC_full = zeros(dof_here,ndof);
        dSTdq_FC_full(:,dofs_here) = dSTdq_FC;
    
        ID(dofs_here,:) = ID(dofs_here,:)+S((ij-1)*6+1:6*ij,dofs_here)'*F_C;
        dID_dq(dofs_here,:) = dID_dq(dofs_here,:)+dSTdq_FC_full+S((ij-1)*6+1:6*ij,dofs_here)'*(M_C*Q_B((i_sig-1)*6+1:6*i_sig,:)+U_S+P_S);
    end
    
    i_sig = i_sig-1;
    ij = ij-1;
    if ~Linkage.OneBasis
        dof_start=dof_start-dof_here;
    end

    % projecting to the tip of parent link
    ip = iLpre(i);
    
    if ip>0
        Ad_g_ini_inv = dinamico_Adjoint(ginv(g_ini((i-1)*4+1:i*4,:)));
        coAd_g_ini = Ad_g_ini_inv';
    
        M_C_tip(6*(ip-1)+1:6*ip,:) = M_C_tip(6*(ip-1)+1:6*ip,:)+coAd_g_ini*M_C*Ad_g_ini_inv;
        F_C_tip(6*(ip-1)+1:6*ip)   = F_C_tip(6*(ip-1)+1:6*ip)+coAd_g_ini*F_C;
        P_S_tip(6*(ip-1)+1:6*ip,:) = P_S_tip(6*(ip-1)+1:6*ip,:)+coAd_g_ini*P_S;
        U_S_tip(6*(ip-1)+1:6*ip,:) = U_S_tip(6*(ip-1)+1:6*ip,:)+coAd_g_ini*U_S;
    end

end

%% Actuation

tau = -Linkage.K*q; %tau = Bu-Kq
dtau_dq = -Linkage.K; %more to add

if Linkage.Actuated

    B = zeros(ndof,nact); %Arranged like: [Bj1 (1D) joints, Bjm (multi) joints, Bsoft]

    N_jact       = Linkage.N_jact; %number of Links whos joints are actuated
    n_jact       = Linkage.n_jact; %total number of joint actutators (3 for spherical joint)
    %revolute, prismatic, helical joints (1D joints)
    Bj1          = Linkage.Bj1; %Generalized Actuation Basis of 1D joints
    na_j1        = size(Bj1,2); 
    B(:,1:na_j1) = Linkage.Bj1;

    %for other joints
    i_jact  = Linkage.i_jact; %indices of Links whos joints are actuated
    i_u     = na_j1+1; %index of columns and us
    i_jactq = Linkage.i_jactq; %indices of actutated qs (for rigid joint)
    
    for ii=na_j1+1:N_jact %Links with actuated multi DOF joints

        i = i_jact(ii); %corresponding Link number
        dof_here = Linkage.CVRods{i}(1).dof;
        us_here = i_u:i_u+dof_here-1;
        dofs_here = i_jactq(us_here);
        if Linkage.VLinks(Linkage.LinkIndex(i)).jointtype=='C' %cylindrical
            B(dofs_here,us_here) = eye(2);
        else %for multijoint it is complex refer to paper
            ij = Linkage.ActuationPrecompute.ij_act(ii);
            S_here = S((ij-1)*6+1:ij*6,i_jactq(i_u:i_u+dof_here-1));
            coAdgstep_here = Adgstepinv((ij-1)*6+1:6*ij,:)';
            Phi_here = Linkage.CVRods{i}(1).Phi;
            coAdgstepPhi_here = coAdgstep_here*Phi_here;
            B(dofs_here,us_here) = S_here'*coAdgstepPhi_here;
            Fk0 = coAdgstepPhi_here*u(us_here);
            dBu_dq_here = compute_dBu_dq_joint(Omega(:,ij),S_here,Phi_here,f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:),Fk0); %partial derivative of B*u for the joint wrt q_here. check also convert to C to make faster
            dtau_dq(dofs_here,dofs_here) = dtau_dq(dofs_here,dofs_here)+dBu_dq_here;
        end
        i_u = i_u+dof_here;
    end

    %cable actuation %combine with FwdKinematics
    if Linkage.n_sact>0
        dof_start = 1;
        for i = 1:N
            dof_here = Linkage.CVRods{i}(1).dof;
            if ~Linkage.OneBasis
                dof_start=dof_start+dof_here;
            end
            for j=1:Linkage.VLinks(Linkage.LinkIndex(i)).npie-1
                na_here = length(Linkage.i_sact{i}{j});
                dof_here = Linkage.CVRods{i}(j+1).dof;
                dofs_here = dof_start:dof_start+dof_here-1;
                if ~Linkage.OneBasis
                    dof_start=dof_start+dof_here;
                end
                if na_here>0
                    Ws = Linkage.CVRods{i}(j+1).Ws;
                    B_here = zeros(dof_here,na_here);
                    dBu_dq_here = zeros(dof_here,dof_here);
                    for ii=1:nip
                        if Ws(ii)>0
                            Phi = Linkage.CVRods{i}(j+1).Phi((ii-1)*6+1:ii*6,:);
                            xi  = Phi*q(dofs_here)+Linkage.CVRods{i}(j+1).xi_star((ii-1)*6+1:ii*6,1);
                            Phi_a = zeros(6,na_here);
                            PHI_AU = zeros(6,6);
                            xihat_123  = [0 -xi(3) xi(2) xi(4);xi(3) 0 -xi(1) xi(5);-xi(2) xi(1) 0 xi(6)];%4th row is avoided to speedup calculation
                            for ia =Linkage.i_sact{i}{j}
                                dc = Linkage.dc{ia,i}{j}(:,ii);
                                dcp = Linkage.dcp{ia,i}{j}(:,ii);
                                [Phi_a(:,ia),PHI_AU_ia] = SoftActuator(u(n_jact+ia),dc,dcp,xihat_123);
                                PHI_AU = PHI_AU+PHI_AU_ia;
                            end
                            B_here = B_here+Ws(ii)*Phi'*Phi_a;
                            dBu_dq_here = dBu_dq_here+Ws(ii)*Phi'*PHI_AU*Phi;
                        end
                    end
                    B(dofs_here,n_jact+Linkage.i_sact{i}{j}) = B_here;
                    dtau_dq(dofs_here,dofs_here) = dtau_dq(dofs_here,dofs_here)+dBu_dq_here;
                end
            end
        end
    end

    tau = tau+B*u;
end
%% Custom Soft Actuation

if Linkage.CA
    [Fact,dFact_dq] = CustomActuation(Linkage,q,g,J,0,zeros(ndof,1),zeros(6*nsig,1),zeros(6*nsig,ndof));
    [tauC,dtauC_dq] = CustomActuation_Qspace(Linkage,Fact,dFact_dq);
    tau = tau+tauC;
    dtau_dq = dtau_dq+dtauC_dq;
end


%% Equilibrium

taumID = tau-ID;
dtaumID_dq = dtau_dq-dID_dq;

if Linkage.nCLj>0 %if there are closed chain joints
    nCLp = Linkage.CLprecompute.nCLp;
    Res = [taumID;e];
    if Linkage.Actuated
        if Linkage.CAI
            Jac = [dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_u), B(:,Linkage.ActuationPrecompute.index_u_u), A';de_dq(:,Linkage.ActuationPrecompute.index_q_u),zeros(nCLp,n_k+nCLp)]...
                 +[B(:,Linkage.ActuationPrecompute.index_u_k), dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_k);zeros(nCLp,n_k), de_dq(:,Linkage.ActuationPrecompute.index_q_k)]*daction_dx;
        else
            Jac = [dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_u), B(:,Linkage.ActuationPrecompute.index_u_u), A';de_dq(:,Linkage.ActuationPrecompute.index_q_u),zeros(nCLp,n_k+nCLp)];
        end
    else
        Jac = [dtaumID_dq, A';de_dq,zeros(nCLp,nCLp)];
    end
else
    Res = taumID;
    if Linkage.Actuated
        if Linkage.CAI
            Jac = [dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_u), B(:,Linkage.ActuationPrecompute.index_u_u)]...
                 +[B(:,Linkage.ActuationPrecompute.index_u_k), dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_k)]*daction_dx;
        else
            Jac = [dtaumID_dq(:,Linkage.ActuationPrecompute.index_q_u), B(:,Linkage.ActuationPrecompute.index_u_u)];
        end
    else
        Jac = dtaumID_dq;
    end
end

if staticsOptions.magnifier
    Res = Res*staticsOptions.magnifierValue;
    Jac = Jac*staticsOptions.magnifierValue;
end

end