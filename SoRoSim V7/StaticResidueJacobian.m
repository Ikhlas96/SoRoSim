[Res, Jac_q, Jac_u, jac_l] = StaticResidueJacobian(Linkage, q, u, l)
    N = Linkage.N;
    ndof = Linkage.ndof;
    nsig = Linkage.nsig;
    nj = Linkage.nj;

    if Linkage.CAI
        [input,dinput_dx] = CustomActuatorStrength(Linkage,q); %CustomActuatorStrength is empty returning only zeros
    end

    % Assigning qu qk and uu etc 
    % if Linkage.Actuated
    %     nact = Linkage.nact;
    %     n_k  = Linkage.ActuationPrecompute.n_k; %number of q_joint inputs
    %     %if n_k>0 rearrangemetns are required to compute q and u in the correct format
    %     if n_k>0
    %         q(Linkage.ActuationPrecompute.index_q_u) = x(1:ndof-n_k);
    %         q(Linkage.ActuationPrecompute.index_q_k) = input(end-n_k+1:end);
    %         u(Linkage.ActuationPrecompute.index_u_k) = input(1:nact-n_k);
    %         u(Linkage.ActuationPrecompute.index_u_u) = x(ndof-n_k+1:ndof);
    %     end
    % end

    %Initialize
    ID = zeros(ndof,1);
    dID_dq = zeros(ndof, ndof);

    Fk = zeros(6*nsig,1);

    %% Forward Kinmatic pass: 

    h = zeros(1,nj);            %Joint length. h=1 for rigid joints
    Omega = zeros(6,nj);        %Joint twist
    Z = zeros(6*nj,ndof);       %Joint basis. Z=Phi for rigid joints (sparse matrix, can we avoid?)
    gstep = zeros(4*nj,4);      %Linkageansformation from X_alpha to X_alpha+1 (0 to 1 for rigid joints)
    Adgstepinv = zeros(6*nj,6); %As the name says!
    T = zeros(6*nj,6);          %Tangent vector at each joint (T(Omega))
    S = zeros(6*nj,ndof);       %S is joint motion subspace (sparse matrix for a reason)
    Q = zeros(6*nj,ndof);       %gravity derivative at joint (sparse matrix for a reason)
    f = zeros(4,nj);            %function of theta, required for the computations of Tangent operator
    fd = zeros(4,nj);           %required for the derivative of Tangent operator
    adjOmegap = zeros(24*nj,6); %Powers of adjOmega (1-4), used later
    
    J = zeros(6*nsig,ndof);   %Jacobian (J is S_B)
    Q_B = zeros(6*nsig,ndof); %Gravity derivatives
    g = zeros(4*nsig,4);      %Fwd kinematics
    
    %For branched chain computation
    g_tip  = repmat(eye(4),N,1);
    J_tip  = zeros(N*6,ndof);
    Q_Btip = zeros(N*6,ndof);
    
    dof_start = 1; %starting dof of current rod
    i_sig = 1;     %current computational point index
    ij = 1;        %current virtual joint index
    
    iLpre = Linkage.iLpre;
    g_ini = Linkage.g_ini;

    for i =1:N
        if iLpre(i) > 0
            g_here = g_tip((iLpre(i)-1)*4+1:iLpre(i)*4,:)*g_ini((i-1)*4+1:i*4,:);
            Ad_g_ini_inv = dinamico_Adjoint(ginv(g_ini((i-1)*4+1:i*4)));
            J_here  = Ad_g_ini_inv*J_tip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
            Q_Bhere = Ad_g_ini_inv*Q_Btip((iLpre(i)-1)*6+1:iLpre(i)*6,:);
        else
            g_here   = g_ini((i-1)*4+1:i*4,:);
            J_here   = zeros(6,ndof);
            Q_Bhere  = zeros(6,ndof);
        end

        J((i_sig-1)*6+1:6*i_sig,:) = J_here;
        Q_B((i_sig-1)*6+1:6*i_sig,:) = Q_Bhere;
        g((i_sig-1)*4+1:4*i_sig,:) = g_here;

        dof_here  = Linkage.CVRods{i}(1).dof;
        dofs_here = dof_start:dof_start+dof_here-1;

        Phi_here = Linkage.CVRods{i}(1).Phi;
        xi_star  = Linkage.CVRods{i}(1).xi_star;
        h(ij) = 1; % This is needed for the softJointKinematics
        

        [Omega(:,ij),Z((ij-1)*6+1:6*ij,dofs_here),gstep((ij-1)*4+1:4*ij,:),T((ij-1)*6+1:6*ij,:),S((ij-1)*6+1:6*ij,dofs_here),...
              f(:,ij),fd(:,ij),adjOmegap((ij-1)*24+1:24*ij,:)] = RigidJointKinematics_mex(Phi_here,xi_star,q(dofs_here)); %
        Adgstepinv((ij-1)*6+1:6*ij,:) = dinamico_Adjoint(ginv(gstep((ij-1)*4+1:4*ij,:)));

        


end